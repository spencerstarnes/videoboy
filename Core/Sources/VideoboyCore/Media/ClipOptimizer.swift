//
//  ClipOptimizer.swift — any clip to a performance-ready SD file (0.4.10).
//
//  Purpose : Copy + Optimize's conversion (proposal §7). Decodes with whatever reads
//            the source (AVFoundation / VideoToolbox for camera and phone formats, the
//            bitstream decoders for DV and MPEG), turns it upright, FITS it into the
//            4:3 SD canvas (letterbox / pillarbox, never stretched), conforms it to
//            29.97 by time, and encodes DV (Performance) or MPEG-2 GOP 6 (Compact).
//  Inputs  : a source URL, an output URL, a preset.
//  Outputs : the file (written by the caller's rules — see OptimizeQueue), a frame count.
//  Connects: `Videoboy --optimize` (the out-of-process helper), which runs this.
//  Extend  : other canvases (0.4.11) replace the fixed 720×480 @ 29.97.
//
//  THREADING: blocking; run it in the helper process, never in the app.
//

import Accelerate
import Foundation

/// What Copy + Optimize writes.
public enum OptimizePreset: String, CaseIterable, Sendable {
    /// DV on the SD NTSC canvas: keeps the DV wedge.
    case performance
    /// MPEG-2 GOP 6, no B-frames, 6 Mb/s: keeps the MPEG wedge, a third of DV's size.
    case compact

    public var displayName: String {
        switch self {
        case .performance: "Performance (DV)"
        case .compact: "Compact (MPEG-2 GOP 6)"
        }
    }

    public var fileExtension: String { self == .performance ? "dv" : "m2v" }
}

public enum ClipOptimizer {

    /// The canvas an optimized file is made for; a file made for another is stale.
    public static let canvasTag = "SD NTSC 29.97"

    public enum OptimizeError: Error, CustomStringConvertible {
        case unreadable(URL)
        case encoder(String)
        case write(String)
        case cancelled
        public var description: String {
            switch self {
            case .unreadable(let url): "\(url.lastPathComponent) could not be read"
            case .encoder(let why): "the encoder failed: \(why)"
            case .write(let why): "could not write: \(why)"
            case .cancelled: "cancelled"
            }
        }
    }

    /// Converts `source` into `output` (overwritten). Returns the frames written.
    public static func optimize(
        _ source: URL, to output: URL, preset: OptimizePreset,
        isCancelled: () -> Bool = { false },
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Int {
        guard let decoder = ClipDecoders.open(source, canvas: .standardDefinition),
              decoder.frameCount > 0, decoder.frameRate > 0 else {
            throw OptimizeError.unreadable(source)
        }
        let rate = StandardDefinition.frameRate
        let seconds = Double(decoder.frameCount) / decoder.frameRate
        let total = max(Int((seconds * rate).rounded()), 1)

        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else {
            throw OptimizeError.write(output.path)
        }
        defer { try? handle.close() }

        let dv: DVEncoder?
        let mpeg: MPEG2Encoder?
        do {
            dv = preset == .performance ? try DVEncoder(standard: .ntsc) : nil
            mpeg = preset == .compact ? try MPEG2Encoder() : nil
        } catch {
            throw OptimizeError.encoder("\(error)")
        }

        var canvas = ImageBuffer(width: StandardDefinition.width, height: StandardDefinition.height)
        var lastSource = -1
        for index in 0..<total {
            if isCancelled() { throw OptimizeError.cancelled }
            // Conform by time: the source frame on screen at this output frame's time.
            let sourceIndex = min(Int(Double(index) * decoder.frameRate / rate), decoder.frameCount - 1)
            if sourceIndex != lastSource, let picture = decoder.image(at: sourceIndex, corruption: .inert) {
                canvas = fitted(picture, quarterTurns: decoder.quarterTurns,
                                displayAspect: decoder.displayAspectRatio)
                lastSource = sourceIndex
            }
            let bytes: [UInt8]
            if let dv {
                guard let frame = dv.encode(image: canvas) else { throw OptimizeError.encoder("DV frame \(index)") }
                bytes = frame
            } else {
                bytes = mpeg?.encode(canvas) ?? []
            }
            if !bytes.isEmpty { handle.write(Data(bytes)) }
            if index % 15 == 0 || index == total - 1 { progress(index + 1, total) }
        }
        if let mpeg { handle.write(Data(mpeg.finish())) }
        return total
    }

    /// A decoded picture turned upright and fitted into black 720×480, preserving its
    /// DISPLAY shape on the 4:3 canvas.
    static func fitted(_ picture: ImageBuffer, quarterTurns: Int, displayAspect: Double?) -> ImageBuffer {
        let width = StandardDefinition.width, height = StandardDefinition.height
        let upright = rotated(picture, quarterTurns: quarterTurns)
        let aspect = displayAspect ?? CanvasGeometry.displayAspect(width: upright.width, height: upright.height)
        let canvasAspect = 4.0 / 3.0
        var fitWidth = width, fitHeight = height
        if aspect > canvasAspect {
            fitHeight = Int((Double(height) * canvasAspect / aspect).rounded())
        } else {
            fitWidth = Int((Double(width) * aspect / canvasAspect).rounded())
        }
        fitWidth = max(2, min(width, fitWidth & ~1))
        fitHeight = max(2, min(height, fitHeight & ~1))
        let x = (width - fitWidth) / 2, y = (height - fitHeight) / 2

        var output = ImageBuffer(width: width, height: height, r: 0, g: 0, b: 0).pixels   // opaque black
        var source = upright.pixels
        source.withUnsafeMutableBytes { sourceRaw in
            output.withUnsafeMutableBytes { outRaw in
                var src = vImage_Buffer(data: sourceRaw.baseAddress, height: vImagePixelCount(upright.height),
                                        width: vImagePixelCount(upright.width), rowBytes: upright.bytesPerRow)
                var dst = vImage_Buffer(data: outRaw.baseAddress!.advanced(by: (y * width + x) * 4),
                                        height: vImagePixelCount(fitHeight), width: vImagePixelCount(fitWidth),
                                        rowBytes: width * 4)
                _ = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return ImageBuffer(width: width, height: height, pixels: output)
    }

    /// Clockwise quarter turns, with vImage (a phone clip is stored sideways).
    static func rotated(_ picture: ImageBuffer, quarterTurns: Int) -> ImageBuffer {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return picture }
        let swaps = turns % 2 == 1
        let outWidth = swaps ? picture.height : picture.width
        let outHeight = swaps ? picture.width : picture.height
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        var source = picture.pixels
        source.withUnsafeMutableBytes { sourceRaw in
            output.withUnsafeMutableBytes { outRaw in
                var src = vImage_Buffer(data: sourceRaw.baseAddress, height: vImagePixelCount(picture.height),
                                        width: vImagePixelCount(picture.width), rowBytes: picture.bytesPerRow)
                var dst = vImage_Buffer(data: outRaw.baseAddress, height: vImagePixelCount(outHeight),
                                        width: vImagePixelCount(outWidth), rowBytes: outWidth * 4)
                var black: [UInt8] = [0, 0, 0, 255]
                // vImage counts turns anticlockwise; a clockwise turn is 4 − n of them.
                _ = vImageRotate90_ARGB8888(&src, &dst, UInt8((4 - turns) % 4), &black, vImage_Flags(kvImageNoFlags))
            }
        }
        return ImageBuffer(width: outWidth, height: outHeight, pixels: output)
    }
}
