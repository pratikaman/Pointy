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
    /// arrow identifier. Returns false if the WindowServer silently ignored
    /// all of them.
    @discardableResult
    static func applyArrow(images: [CGImage], hotspot: CGPoint) -> Bool {
        guard let mainConnection, let registerCursor else { return false }
        let cid = mainConnection()
        for name in arrowNames {
            var seed: Int32 = 0
            _ = registerCursor(
                cid, name, true, true,
                CGSize(width: canvasPoints, height: canvasPoints), hotspot,
                1, 0, images as CFArray, &seed
            )
        }
        dockOverride?(cid, false)
        return arrowIsOurs()
    }

    /// Reads back what is actually registered under the arrow identifiers and
    /// checks any of them matches our canvas; a mismatch on all of them means
    /// our cursor is not showing (e.g. the WindowServer ignored the writes).
    static func arrowIsOurs() -> Bool {
        guard let mainConnection, let createImage else { return false }
        let cid = mainConnection()
        for name in arrowNames {
            var hot = CGPoint.zero
            if let img = createImage(cid, name, &hot)?.takeRetainedValue(),
               img.width == Int(canvasPoints), img.height == Int(canvasPoints) {
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
        return [32, 64].compactMap { px in
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
}
