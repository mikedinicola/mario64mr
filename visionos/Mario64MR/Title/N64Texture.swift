import CoreGraphics
import Foundation
import ImageIO

/// A PNG from the resource pack back into the N64 texture format the game's code expects (as the decomp's
/// n64graphics makes them): rgba16 (5-5-5-1, big-endian), rgba32, ia16, ia8, i8
enum N64Texture {
    static func encode(png: Data, format: String, width: Int, height: Int) -> [UInt8]? {
        guard let rgba = decode(png, width: width, height: height) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)
        for i in 0..<(width * height) {
            let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2], a = rgba[i * 4 + 3]
            switch format {
            case "rgba16":
                let v = UInt16(r >> 3) << 11 | UInt16(g >> 3) << 6 | UInt16(b >> 3) << 1 | (a >= 128 ? 1 : 0)
                out += [UInt8(v >> 8), UInt8(v & 0xFF)]
            case "rgba32": out += [r, g, b, a]
            case "ia16": out += [r, a]
            case "ia8": out.append((r >> 4) << 4 | a >> 4)
            case "i8": out.append(r)
            default: return nil
            }
        }
        return out
    }

    /// The image as straight (not premultiplied) RGBA8, `width` by `height`, top row first
    private static func decode(_ png: Data, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { return nil }
        // (CGContext draws only premultiplied: the alpha is undone after)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 && pixels[i + 3] < 255 {
            let a = Int(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
        }
        return pixels
    }
}
