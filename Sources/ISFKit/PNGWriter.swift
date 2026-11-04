import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A frame read back from a bgra8Unorm texture, top row first.
public struct RenderedImage: Sendable {
    public var width: Int
    public var height: Int
    public var bgra: Data

    public init(width: Int, height: Int, bgra: Data) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// (r, g, b, a) of one pixel.
    public func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3])
    }
}

public struct PNGWriteError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

public enum PNGWriter {
    /// Writes straight (non-premultiplied) alpha, which is what an ISF shader outputs.
    /// The CGImage is built from a data provider because CGBitmapContext only supports premultiplied alpha.
    public static func write(_ image: RenderedImage, to url: URL) throws {
        guard let provider = CGDataProvider(data: image.bgra as CFData) else {
            throw PNGWriteError(description: "cannot wrap pixel data")
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
        guard let cg = CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw PNGWriteError(description: "cannot create image")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PNGWriteError(description: "cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PNGWriteError(description: "cannot write \(url.path)")
        }
    }
}
