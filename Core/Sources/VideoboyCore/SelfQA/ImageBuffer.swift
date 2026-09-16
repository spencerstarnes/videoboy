//
//  ImageBuffer.swift — a plain 8-bit RGBA image in memory, and PNG I/O for it.
//
//  Purpose : The common currency of the self-QA harness. Anything Claude wants to
//            look at — an offscreen Metal render, a decoded DV frame, a captured
//            DVC100 frame — becomes an `ImageBuffer` and can then be written to PNG,
//            asserted on, or diffed against a fixture.
//  Inputs  : raw RGBA8 bytes (row-major, 4 bytes per pixel, no padding), or a PNG file.
//  Outputs : PNG files under selfqa/out/, and pixel accessors for assertions.
//  Connects: OffscreenRenderer (Metal readback), CaptureSource (camera frames),
//            FrameAssertions (checks), DVDecoder (decoded frames).
//  Extend  : keep this type dumb. Analysis belongs in FrameAssertions, not here.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit-per-channel RGBA image held in a flat byte array.
///
/// Storage is row-major with no row padding: pixel (x, y) starts at
/// `(y * width + x) * 4` and runs R, G, B, A.
public struct ImageBuffer {
    /// Bytes per pixel. RGBA8 is fixed for the whole harness — no format zoo.
    public static let bytesPerPixel = 4

    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    /// Bytes in one row of `pixels`.
    public var bytesPerRow: Int { width * ImageBuffer.bytesPerPixel }

    /// Wraps existing RGBA8 bytes. Traps if the byte count does not match the
    /// stated dimensions — a size mismatch here is a programming error, not a
    /// runtime condition worth recovering from.
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "ImageBuffer needs positive dimensions")
        precondition(
            pixels.count == width * height * ImageBuffer.bytesPerPixel,
            "ImageBuffer expected \(width * height * ImageBuffer.bytesPerPixel) bytes, got \(pixels.count)"
        )
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// An opaque black image of the given size.
    public init(width: Int, height: Int) {
        var bytes = [UInt8](repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        for index in stride(from: 3, to: bytes.count, by: ImageBuffer.bytesPerPixel) {
            bytes[index] = 255
        }
        self.init(width: width, height: height, pixels: bytes)
    }

    /// Reads the pixel at (x, y) as (red, green, blue, alpha).
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel(\(x),\(y)) out of bounds")
        let offset = (y * width + x) * ImageBuffer.bytesPerPixel
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// A smaller copy, keeping the aspect ratio.
    ///
    /// Box-averaged rather than nearest-neighbour: a thumbnail of interlaced SD made
    /// by point-sampling shows every other field line and reads as flicker, which is
    /// a poor advertisement for a clip that is actually fine. Averaging costs a few
    /// milliseconds once per cached frame.
    public func scaled(toWidth newWidth: Int) -> ImageBuffer {
        guard newWidth > 0, width > 0, height > 0, newWidth < width else { return self }
        let newHeight = max(1, Int((Double(height) * Double(newWidth) / Double(width)).rounded()))
        var output = ImageBuffer(width: newWidth, height: newHeight)

        for y in 0..<newHeight {
            let sourceTop = y * height / newHeight
            let sourceBottom = max(sourceTop + 1, (y + 1) * height / newHeight)
            for x in 0..<newWidth {
                let sourceLeft = x * width / newWidth
                let sourceRight = max(sourceLeft + 1, (x + 1) * width / newWidth)

                var red = 0, green = 0, blue = 0, count = 0
                for sourceY in sourceTop..<min(sourceBottom, height) {
                    for sourceX in sourceLeft..<min(sourceRight, width) {
                        let sample = pixel(x: sourceX, y: sourceY)
                        red += Int(sample.r)
                        green += Int(sample.g)
                        blue += Int(sample.b)
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                output.setPixel(
                    x: x, y: y,
                    r: UInt8(red / count), g: UInt8(green / count), b: UInt8(blue / count))
            }
        }
        return output
    }

    /// Writes the pixel at (x, y).
    public mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "setPixel(\(x),\(y)) out of bounds")
        let offset = (y * width + x) * ImageBuffer.bytesPerPixel
        pixels[offset] = r
        pixels[offset + 1] = g
        pixels[offset + 2] = b
        pixels[offset + 3] = a
    }

    /// Rebuilds the buffer from BGRA bytes, which is what Metal's common
    /// `.bgra8Unorm` textures and CoreVideo's `32BGRA` capture frames hand back.
    public static func fromBGRA(width: Int, height: Int, bgra: [UInt8]) -> ImageBuffer {
        var rgba = bgra
        for index in stride(from: 0, to: rgba.count, by: bytesPerPixel) {
            rgba.swapAt(index, index + 2)
        }
        return ImageBuffer(width: width, height: height, pixels: rgba)
    }
}

// MARK: - PNG I/O

public extension ImageBuffer {
    /// Errors from reading or writing PNG files. All are reported, never swallowed.
    enum ImageIOError: Error, CustomStringConvertible {
        case cannotCreateDestination(URL)
        case cannotEncode(URL)
        case cannotOpenSource(URL)
        case cannotDecode(URL)

        public var description: String {
            switch self {
            case .cannotCreateDestination(let url): "cannot create PNG destination at \(url.path)"
            case .cannotEncode(let url): "cannot encode PNG at \(url.path)"
            case .cannotOpenSource(let url): "cannot open image at \(url.path)"
            case .cannotDecode(let url): "cannot decode image at \(url.path)"
            }
        }
    }

    /// Builds a `CGImage` view of these pixels.
    func makeCGImage() -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Writes this buffer to `url` as a PNG, creating parent directories as needed.
    func writePNG(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let image = makeCGImage() else { throw ImageIOError.cannotEncode(url) }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ImageIOError.cannotCreateDestination(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageIOError.cannotEncode(url) }
        Log.info(.selfqa, "wrote \(width)x\(height) PNG -> \(url.path)")
    }

    /// Loads a PNG (or any ImageIO-readable file) back into an RGBA8 buffer.
    static func readPNG(from url: URL) throws -> ImageBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageIOError.cannotOpenSource(url)
        }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let success: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw ImageIOError.cannotDecode(url) }
        return ImageBuffer(width: width, height: height, pixels: bytes)
    }
}
