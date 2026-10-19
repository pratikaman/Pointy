import AppKit

/// Talks to the WindowServer's cursor registration table using the same
/// private CoreGraphics/SkyLight calls Mousecape uses. Registrations are
/// per-login-session: they survive the app quitting and clear on logout.
enum CursorEngine {
    static let canvasPoints: CGFloat = 32

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias RegisterCursorFn = @convention(c) (
        Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint,
        UInt, CGFloat, CFArray, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias CreateImageFn = @convention(c) (
        Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGPoint>
    ) -> Unmanaged<CGImage>?
    private typealias UnregisterAllFn = @convention(c) (Int32) -> Int32
    private typealias NameForCursorFn = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    private typealias DockOverrideFn = @convention(c) (Int32, Bool) -> Void

    private static func sym<T>(_ name: String, as type: T.Type) -> T? {
        guard let ptr = dlsym(dlopen(nil, RTLD_NOW), name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    private static let mainConnection = sym("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let registerCursor = sym("CGSRegisterCursorWithImages", as: RegisterCursorFn.self)
    private static let createImage = sym("CGSCreateRegisteredCursorImage", as: CreateImageFn.self)
    private static let unregisterAll = sym("CoreCursorUnregisterAll", as: UnregisterAllFn.self)
    private static let nameForCursor = sym("CGSCursorNameForSystemCursor", as: NameForCursorFn.self)
    private static let dockOverride = sym("CGSSetDockCursorOverride", as: DockOverrideFn.self)

    /// On macOS 26+ Apple aliased the arrow under new identifiers (notably
    /// "com.apple.coregraphics.ArrowS", system cursor id 100); registering only
    /// the legacy name silently does nothing. Enumerate the system cursor ids
    /// and override every arrow-related name.
    private static let arrowNames: [String] = {
        var names = ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowCtx"]
        if let nameForCursor {
            for id in 0..<128 {
                guard let c = nameForCursor(Int32(id)), let s = String(validatingUTF8: c),
                      s.lowercased().contains("arrow"), !names.contains(s) else { continue }
                names.append(s)
            }
        }
        return names
    }()

    /// Registers 1x + 2x images as the system arrow cursor under every known
    /// arrow identifier. Animated cursors stack their frames top to bottom in
    /// each image. Returns false if the WindowServer silently ignored all of them.
    @discardableResult
    static func applyArrow(images: [CGImage], hotspot: CGPoint,
                           frameCount: Int = 1, frameDuration: CGFloat = 0) -> Bool {
        guard let mainConnection, let registerCursor else { return false }
        let cid = mainConnection()
        for name in arrowNames {
            var seed: Int32 = 0
            _ = registerCursor(
                cid, name, true, true,
                CGSize(width: canvasPoints, height: canvasPoints), hotspot,
                UInt(frameCount), frameDuration, images as CFArray, &seed
            )
        }
        dockOverride?(cid, false)
        return arrowIsOurs()
    }

    /// Reads back what is actually registered under the arrow identifiers and
    /// checks any of them matches our canvas (animated ones read back as the
    /// whole frame strip); a mismatch on all of them means our cursor is not
    /// showing (e.g. the WindowServer ignored the writes).
    static func arrowIsOurs() -> Bool {
        guard let mainConnection, let createImage else { return false }
        let cid = mainConnection()
        for name in arrowNames {
            var hot = CGPoint.zero
            if let img = createImage(cid, name, &hot)?.takeRetainedValue(),
               img.width == Int(canvasPoints), img.height % Int(canvasPoints) == 0 {
                return true
            }
        }
        return false
    }

    static func reset() {
        guard let mainConnection, let unregisterAll else { return }
        _ = unregisterAll(mainConnection())
    }

    /// Best-effort hint: is Accessibility pointer color/size customization on?
    static func pointerThemingActive() -> Bool {
        let domain = "com.apple.universalaccess" as CFString
        if let v = CFPreferencesCopyAppValue("cursorIsCustomized" as CFString, domain) as? Bool, v {
            return true
        }
        if let size = CFPreferencesCopyAppValue("mouseDriverCursorSize" as CFString, domain) as? Double,
           abs(size - 1.0) > 0.01 {
            return true
        }
        return false
    }

    // MARK: - Rendering

    /// Renders a square sRGB bitmap of the given pixel size using the draw block.
    private static func renderCanvas(pixels: Int, draw: (CGFloat) -> Void) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 4 * pixels, bitsPerPixel: 32
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        let tagged = rep.retagging(with: .sRGB) ?? rep
        return tagged.cgImage
    }

    /// 1x + 2x cursor images for an emoji.
    static func emojiImages(_ emoji: String) -> [CGImage] {
        [32, 64].compactMap { px in
            renderCanvas(pixels: px) { side in
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: side * 0.78)]
                let str = emoji as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(
                    at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2),
                    withAttributes: attrs
                )
            }
        }
    }

    /// 1x + 2x cursor images for an image file, aspect-fit on the square canvas.
    static func fileImages(_ url: URL) -> [CGImage] {
        guard let source = NSImage(contentsOf: url), source.isValid else { return [] }
        return fitImages(source)
    }

    /// 1x + 2x frame strips for an animated cursor: each frame aspect-fit on
    /// the square canvas, stacked top to bottom.
    static func stripImages(_ frames: [CGImage]) -> [CGImage] {
        let fitted = frames.map { fitImages(NSImage(cgImage: $0, size: .zero)) }
        guard fitted.allSatisfy({ $0.count == 2 }) else { return [] }
        return (0..<2).compactMap { scale in
            let column = fitted.map { $0[scale] }
            let side = column[0].width
            guard let ctx = CGContext(
                data: nil, width: side, height: side * column.count, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            // CG's origin is bottom-left, so frame 0 goes at the highest y.
            for (i, frame) in column.enumerated() {
                ctx.draw(frame, in: CGRect(x: 0, y: (column.count - 1 - i) * side, width: side, height: side))
            }
            return ctx.makeImage()
        }
    }

    private static func fitImages(_ source: NSImage) -> [CGImage] {
        [32, 64].compactMap { px in
            renderCanvas(pixels: px) { side in
                let sourceSize = source.size
                guard sourceSize.width > 0, sourceSize.height > 0 else { return }
                let scale = min(side / sourceSize.width, side / sourceSize.height)
                let w = sourceSize.width * scale
                let h = sourceSize.height * scale
                source.draw(
                    in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1
                )
            }
        }
    }

    // MARK: - Windows animated cursors

    /// The WindowServer refuses animated cursors with more frames than this.
    static let maxFrames = 24

    /// Parses a Windows animated cursor (.ani: a RIFF "ACON" file whose frames
    /// are embedded .cur/.ico images) into frames in play order plus seconds
    /// per frame. The WindowServer plays one fixed rate, so per-step rates are
    /// averaged, and animations longer than `maxFrames` are subsampled.
    static func aniFrames(_ data: Data) -> (frames: [CGImage], frameDuration: CGFloat)? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return 0 }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func tag(_ at: Int) -> String {
            String(decoding: bytes[min(at, bytes.count)..<min(at + 4, bytes.count)], as: UTF8.self)
        }
        func decodeIcon(_ range: Range<Int>) -> CGImage? {
            guard let src = CGImageSourceCreateWithData(Data(bytes[range]) as CFData, nil) else { return nil }
            // A .cur can hold several sizes; the largest gives the crispest 2x.
            return (0..<CGImageSourceGetCount(src))
                .compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
                .max { $0.width < $1.width }
        }
        guard tag(0) == "RIFF", tag(8) == "ACON" else { return nil }

        var icons: [CGImage?] = [], rates: [Int] = [], sequence: [Int] = [], dispRate = 0
        var p = 12
        while p + 8 <= bytes.count {
            let body = p + 8, size = u32(p + 4), bodyEnd = min(body + size, bytes.count)
            switch tag(p) {
            case "anih": dispRate = u32(body + 28)
            case "rate": rates = stride(from: body, to: bodyEnd - 3, by: 4).map(u32)
            case "seq ": sequence = stride(from: body, to: bodyEnd - 3, by: 4).map(u32)
            // Step into the frame list; its "icon" chunks are walked like top-level ones.
            case "LIST" where tag(body) == "fram": p = body + 4; continue
            case "icon": icons.append(decodeIcon(body..<bodyEnd))
            default: break
            }
            p = body + size + (size & 1)
        }

        let order = sequence.isEmpty ? Array(icons.indices) : sequence.filter(icons.indices.contains)
        let step = max(1, (order.count + maxFrames - 1) / maxFrames)
        let frames = stride(from: 0, to: order.count, by: step).compactMap { icons[order[$0]] }
        guard !frames.isEmpty else { return nil }
        // ponytail: averaged rate, so uneven per-step timings play evenly.
        let jiffies = rates.isEmpty ? dispRate : rates.reduce(0, +) / rates.count
        return (frames, CGFloat(max(jiffies, 1) * step) / 60)
    }
}
