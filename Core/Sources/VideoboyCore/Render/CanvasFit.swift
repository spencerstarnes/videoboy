//
//  CanvasFit.swift — putting a source picture into the canvas, the right shape.
//
//  Purpose : Every source must reach the graph at the CANVAS size and shape. Before
//            this, an HD clip entered at 1920×1080: every per-channel effect ran on
//            six times the pixels, and the mixer then squeezed the 16:9 picture into
//            4:3. Here the picture is decoded no larger than the canvas needs
//            (`decodeSize`) and one GPU pass (`fit`) places it — fitted, filled or
//            stretched, turned upright — into a canvas-sized target.
//  Inputs  : the canvas's pixel size, a source's display aspect and rotation.
//  Outputs : a decode size for the decoders; a canvas-sized texture from `fit`.
//  Connects: ClipSourceNode (the fit), AVFClipDecoder and MPEGStreamDecoder (the
//            decode size), MetalContext.fitPipeline (the shader).
//  Extend  : a new canvas is just another `CanvasGeometry`; nothing here assumes SD.
//
//  DISPLAY ASPECT, NOT PIXEL COUNT. An SD raster (720×480, 720×576, 704×480) is shown
//  4:3 whatever its pixel count says — its pixels are not square. Everything else is
//  treated as square-pixelled unless the file says otherwise. All placement maths is
//  done in display units, then mapped to pixels.
//

import Foundation
import Metal
import simd

/// A picture raster: its pixel size and the shape it is shown at.
public struct CanvasGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The project canvas until the canvas becomes a setting (proposal §6).
    public static let standardDefinition = CanvasGeometry(
        width: StandardDefinition.width, height: StandardDefinition.height)

    /// Width over height as SHOWN.
    public var displayAspect: Double { Self.displayAspect(width: width, height: height) }

    /// The shown shape of a raster: 4:3 for the standard-definition rasters, whose
    /// pixels are not square; the pixel ratio for everything else.
    public static func displayAspect(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        let standardRaster = (width == 720 || width == 704) && [480, 486, 576].contains(height)
        return standardRaster ? 4.0 / 3.0 : Double(width) / Double(height)
    }

    /// How big to decode a source so that, placed in this canvas, it has at least one
    /// decoded pixel per canvas pixel — even when it FILLS (the most demanding case) —
    /// and never more than the file holds.
    ///
    /// - Parameters:
    ///   - sourceAspect: the source's display aspect, upright.
    ///   - nativeSize: the source's stored pixel size, upright.
    /// - Returns: an even, upright, square-pixelled size.
    public func decodeSize(sourceAspect: Double, nativeSize: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard sourceAspect > 0, nativeSize.width > 0, nativeSize.height > 0 else {
            return nativeSize
        }
        // In square units at canvas height: the canvas is (aspect × h) wide, h high.
        let canvasHeight = Double(height)
        let neededHeight = max(canvasHeight, canvasHeight * displayAspect / sourceAspect)
        let scale = min(1.0, neededHeight / Double(nativeSize.height))
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(nativeSize.height) * scale * sourceAspect), even(Double(nativeSize.height) * scale))
    }

    /// Where a picture of `sourceAspect` sits in this canvas, in canvas UV (0...1).
    public func placement(sourceAspect: Double, framing: PreviewFill) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let canvas = CGSize(width: displayAspect, height: 1)
        // `centre` means native pixel size, which has no meaning across rasters of
        // different shapes; a source is fitted instead.
        let mode: PreviewFill = framing == .centre ? .fit : framing
        let rect = mode.rect(sourceSize: CGSize(width: sourceAspect, height: 1), in: canvas)
        return (SIMD2(Float(rect.minX / canvas.width), Float(rect.minY / canvas.height)),
                SIMD2(Float(rect.width / canvas.width), Float(rect.height / canvas.height)))
    }
}

/// Places source pictures into a canvas-sized target on the GPU. One per source; it
/// owns (and reuses) its target, so nothing is allocated per frame.
public final class CanvasFit {

    private let metal: MetalContext
    private let label: String
    private var target: MTLTexture?

    public init(context: MetalContext, label: String) {
        self.metal = context
        self.label = label
    }

    /// Whether a picture can go into the canvas untouched.
    public static func isIdentity(
        texture: MTLTexture, sourceAspect: Double, quarterTurns: Int, canvas: CanvasGeometry
    ) -> Bool {
        texture.width == canvas.width && texture.height == canvas.height
            && quarterTurns % 4 == 0
            && abs(sourceAspect - canvas.displayAspect) < 0.01
    }

    /// Draws `source` into this fitter's canvas-sized target and returns it.
    /// Submits without waiting, like every other pass.
    public func fit(
        _ source: MTLTexture, sourceAspect: Double, quarterTurns: Int,
        framing: PreviewFill, canvas: CanvasGeometry
    ) -> MTLTexture? {
        if target == nil || target?.width != canvas.width || target?.height != canvas.height {
            target = metal.makeRenderTarget(width: canvas.width, height: canvas.height, label: "\(label)-fit")
        }
        guard let target else { return nil }

        struct Params {
            var origin: SIMD2<Float>
            var size: SIMD2<Float>
            var quarterTurns: Int32
        }
        let placed = canvas.placement(sourceAspect: sourceAspect, framing: framing)
        var params = Params(origin: placed.origin, size: placed.size, quarterTurns: Int32(quarterTurns & 3))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(label) could not encode its canvas fit")
            return nil
        }
        encoder.label = "\(label)-fit"
        encoder.setRenderPipelineState(metal.fitPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        metal.submit(commandBuffer, label: "\(label) canvas fit")
        return target
    }
}
