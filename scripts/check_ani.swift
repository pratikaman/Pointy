// Self-check for the .ani parser and frame strips. Run:
//   mkdir -p build && swiftc -parse-as-library Sources/CursorEngine.swift scripts/check_ani.swift -o build/check_ani && build/check_ani
import AppKit

@main
struct CheckAni {
    static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }

    /// Encodes as .ico, then optionally flips the header to .cur (type 2) like real .ani frames.
    static func icon(_ img: CGImage, cur: Bool) -> [UInt8] {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "com.microsoft.ico" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        precondition(CGImageDestinationFinalize(dest))
        var bytes = [UInt8](out as Data)
        if cur { bytes[2] = 2 }
        return bytes
    }

    static func le(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le(body.count) + body + (body.count % 2 == 1 ? [0] : [])
    }

    static func ani(icons: [[UInt8]], dispRate: Int, sequence: [Int]? = nil, rates: [Int]? = nil) -> Data {
        let steps = sequence?.count ?? icons.count
        var anih = [36, icons.count, steps, 0, 0, 0, 0, dispRate].flatMap(le)
        anih += le(sequence == nil ? 1 : 3)
        var body = Array("ACON".utf8) + chunk("anih", anih)
        if let rates { body += chunk("rate", rates.flatMap(le)) }
        if let sequence { body += chunk("seq ", sequence.flatMap(le)) }
        body += chunk("LIST", Array("fram".utf8) + icons.flatMap { chunk("icon", $0) })
        return Data(chunk("RIFF", body))
    }

    /// Dominant channel (0 = red, 1 = green, 2 = blue) of the pixel at (x, y) from the top.
    static func channel(_ img: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: y - img.height + 1, width: img.width, height: img.height))
        return px[0..<3].indices.max { px[$0] < px[$1] }!
    }

    static func main() {
        let icons = [solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1)].enumerated().map { icon($1, cur: $0 != 1) }

        // Plain: frames in file order at the header rate.
        let plain = CursorEngine.aniFrames(ani(icons: icons, dispRate: 10))!
        assert(plain.frames.map { channel($0, x: 16, y: 16) } == [0, 1, 2])
        assert(abs(plain.frameDuration - 10.0 / 60) < 1e-9)

        // 30 sequenced steps > 24: every 2nd step is kept and each frame lasts twice as long.
        let seq = (0..<30).map { $0 % 3 }
        let long = CursorEngine.aniFrames(ani(icons: icons, dispRate: 10, sequence: seq,
                                              rates: Array(repeating: 4, count: 30)))!
        assert(long.frames.count == 15)
        assert(long.frames.map { channel($0, x: 16, y: 16) } == stride(from: 0, to: 30, by: 2).map { seq[$0] })
        assert(abs(long.frameDuration - 8.0 / 60) < 1e-9)

        assert(CursorEngine.aniFrames(Data("not a cursor".utf8)) == nil)

        // Strips: 1x and 2x, frame 0 on top.
        let strips = CursorEngine.stripImages(plain.frames)
        assert(strips.map { "\($0.width)x\($0.height)" } == ["32x96", "64x192"])
        assert([0, 1, 2].map { channel(strips[1], x: 32, y: 64 * $0 + 32) } == [0, 1, 2])

        print("ani checks passed")
    }
}
