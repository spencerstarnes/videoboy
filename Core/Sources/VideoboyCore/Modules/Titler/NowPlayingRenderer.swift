//
//  NowPlayingRenderer.swift — draws the Now Playing card into a frame.
//
//  Purpose : The picture behind the Now Playing generator: title, artist, album,
//            artwork and a progress bar in one of three looks (NowPlayingTemplate),
//            on black so it keys or screens cleanly over a mix.
//  Inputs  : a track (or nil), a look, an opacity, whether to draw progress.
//  Outputs : an RGBA `ImageBuffer` at the canvas size.
//  Connects: GeneratorSourceNode (.nowPlaying), which draws only when something
//            visible changed and uploads through TextureUploader.
//  Extend  : a new look is a case in NowPlayingTemplate and a branch in `draw`.
//
//  Core Graphics + Core Text, CPU: a few milliseconds, and only when the track,
//  progress (1% steps) or fade changes — never every frame.
//

import CoreGraphics
import CoreText
import Foundation

public enum NowPlayingRenderer {

    public static func render(
        _ track: NowPlayingTrack?, status: String, template: NowPlayingTemplate,
        opacity: Double, showsProgress: Bool,
        width: Int = StandardDefinition.width, height: Int = StandardDefinition.height
    ) -> ImageBuffer {
        var pixels = ImageBuffer(width: width, height: height, r: 0, g: 0, b: 0).pixels
        let alpha = CGFloat(min(max(opacity, 0), 1))
        pixels.withUnsafeMutableBytes { raw in
            guard alpha > 0, let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Top-left origin, like the rest of the app's images.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setAlpha(alpha)
            draw(track, status: status, template: template, showsProgress: showsProgress,
                 in: context, width: CGFloat(width), height: CGFloat(height))
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    private static func draw(
        _ track: NowPlayingTrack?, status: String, template: NowPlayingTemplate, showsProgress: Bool,
        in context: CGContext, width: CGFloat, height: CGFloat
    ) {
        // Title-safe: 10% in from each edge (SD analog output crops the edges).
        let safe = CGRect(x: width * 0.1, y: height * 0.1, width: width * 0.8, height: height * 0.8)
        let title = track?.title ?? "Nothing playing"
        let artist = track?.artist ?? (track == nil ? status : "")
        let album = track?.album ?? ""

        switch template {
        case .ticker:
            let line = [title, artist].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            text(line.uppercased(), size: 22, weight: .semibold, at: CGPoint(x: safe.minX, y: safe.maxY - 30),
                 maxWidth: safe.width, in: context)
            if showsProgress, let progress = track?.progress {
                bar(progress, frame: CGRect(x: safe.minX, y: safe.maxY - 4, width: safe.width, height: 3), in: context)
            }
        case .lowerThird:
            let slab = CGRect(x: safe.minX, y: safe.maxY - 110, width: safe.width, height: 110)
            context.setFillColor(CGColor(gray: 0.1, alpha: 0.85))
            context.addPath(CGPath(roundedRect: slab, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
            var textX = slab.minX + 16
            if template.showsArtwork, let artwork = track?.artwork {
                let square = CGRect(x: slab.minX + 12, y: slab.minY + 12, width: 86, height: 86)
                image(artwork, in: square, context: context)
                textX = square.maxX + 16
            }
            let textWidth = slab.maxX - textX - 16
            text(title, size: 26, weight: .bold, at: CGPoint(x: textX, y: slab.minY + 16), maxWidth: textWidth, in: context)
            text(artist, size: 18, weight: .regular, at: CGPoint(x: textX, y: slab.minY + 50), maxWidth: textWidth, in: context)
            if showsProgress, let progress = track?.progress {
                bar(progress, frame: CGRect(x: textX, y: slab.maxY - 20, width: textWidth, height: 4), in: context)
            }
        case .card:
            let side: CGFloat = 200
            let artFrame = CGRect(x: (width - side) / 2, y: safe.minY + 10, width: side, height: side)
            if let artwork = track?.artwork {
                image(artwork, in: artFrame, context: context)
            } else {
                context.setFillColor(CGColor(gray: 0.2, alpha: 1))
                context.fill(artFrame)
            }
            centred(title, size: 28, weight: .bold, y: artFrame.maxY + 18, width: width, in: context)
            centred(artist, size: 20, weight: .regular, y: artFrame.maxY + 56, width: width, in: context)
            centred(album, size: 16, weight: .regular, y: artFrame.maxY + 86, width: width, in: context, gray: 0.7)
            if showsProgress, let progress = track?.progress {
                bar(progress, frame: CGRect(x: width * 0.3, y: artFrame.maxY + 118, width: width * 0.4, height: 4), in: context)
            }
        }
    }

    // MARK: - Drawing helpers

    private static func font(_ size: CGFloat, _ weight: CGFloat) -> CTFont {
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: "Helvetica Neue", kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private enum Weight { case regular, semibold, bold
        var value: CGFloat { self == .regular ? 0 : (self == .semibold ? 0.3 : 0.4) }
    }

    private static func line(_ string: String, size: CGFloat, weight: Weight, gray: CGFloat) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(size, weight.value),
            // NTSC-legal white (235 of 255), not full-scale.
            kCTForegroundColorAttributeName: CGColor(gray: gray * 235 / 255, alpha: 1)
        ]
        return CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
    }

    /// Draws one line with its top-left at `point`, truncated with … to `maxWidth`.
    private static func text(_ string: String, size: CGFloat, weight: Weight, at point: CGPoint,
                             maxWidth: CGFloat, in context: CGContext, gray: CGFloat = 1) {
        guard !string.isEmpty else { return }
        var drawn = line(string, size: size, weight: weight, gray: gray)
        if CTLineGetTypographicBounds(drawn, nil, nil, nil) > Double(maxWidth),
           let truncated = CTLineCreateTruncatedLine(drawn, Double(maxWidth), .end,
                                                     line("…", size: size, weight: weight, gray: gray)) {
            drawn = truncated
        }
        context.saveGState()
        // Core Text draws upright in a y-up space: flip back locally.
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + size)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(drawn, context)
        context.restoreGState()
    }

    private static func centred(_ string: String, size: CGFloat, weight: Weight, y: CGFloat,
                                width: CGFloat, in context: CGContext, gray: CGFloat = 1) {
        guard !string.isEmpty else { return }
        let measured = CGFloat(CTLineGetTypographicBounds(line(string, size: size, weight: weight, gray: gray), nil, nil, nil))
        let maxWidth = width * 0.8
        let x = (width - min(measured, maxWidth)) / 2
        text(string, size: size, weight: weight, at: CGPoint(x: x, y: y), maxWidth: maxWidth, in: context, gray: gray)
    }

    private static func bar(_ progress: Double, frame: CGRect, in context: CGContext) {
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        context.fill(frame)
        context.setFillColor(CGColor(gray: 235 / 255, alpha: 1))
        context.fill(CGRect(x: frame.minX, y: frame.minY,
                            width: frame.width * CGFloat(min(max(progress, 0), 1)), height: frame.height))
    }

    private static func image(_ buffer: ImageBuffer, in frame: CGRect, context: CGContext) {
        var pixels = buffer.pixels
        pixels.withUnsafeMutableBytes { raw in
            guard let provider = CGDataProvider(data: Data(raw) as CFData),
                  let image = CGImage(width: buffer.width, height: buffer.height, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: buffer.bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return }
            context.saveGState()
            // The context is flipped (top-left origin); CGImage draws y-up.
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: frame.size))
            context.restoreGState()
        }
    }
}
