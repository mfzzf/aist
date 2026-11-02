import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screenshots are downscaled before upload: a 3024px Retina capture costs more and is no more legible to the model.
public enum ImageCodec {
    public enum CodecError: Error { case encodeFailed, decodeFailed }

    public static func jpeg(_ image: CGImage, maxDimension: Int = 2048, quality: Double = 0.8) throws -> Data {
        let scaled = downscale(image, maxDimension: maxDimension) ?? image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CodecError.encodeFailed
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CodecError.encodeFailed }
        return data as Data
    }

    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw CodecError.decodeFailed }
        return image
    }

    static func downscale(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return nil }
        let scale = Double(maxDimension) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
