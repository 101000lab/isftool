import CoreGraphics
import Foundation
import ImageIO
@testable import ISFKit

/// Reads a PNG back without going through CGBitmapContext, which would premultiply the alpha.
enum PNGReader {
    static func read(_ url: URL) -> RenderedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cg.bitsPerPixel == 32, cg.bitsPerComponent == 8,
              let data = cg.dataProvider?.data as Data?
        else { return nil }
        let alphaFirst = [.first, .noneSkipFirst, .premultipliedFirst].contains(cg.alphaInfo)
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        var bgra = Data(count: cg.width * cg.height * 4)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let s = y * cg.bytesPerRow + x * 4
                var p = [data[s], data[s + 1], data[s + 2], data[s + 3]]
                if little { p.reverse() }
                // p is now in memory order for big endian: ARGB when alpha comes first, RGBA otherwise.
                let (r, g, b, a) = alphaFirst ? (p[1], p[2], p[3], p[0]) : (p[0], p[1], p[2], p[3])
                let d = (y * cg.width + x) * 4
                bgra[d] = b; bgra[d + 1] = g; bgra[d + 2] = r; bgra[d + 3] = a
            }
        }
        return RenderedImage(width: cg.width, height: cg.height, bgra: bgra)
    }
}
