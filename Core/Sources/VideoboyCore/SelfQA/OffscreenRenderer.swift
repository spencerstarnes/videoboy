//
//  OffscreenRenderer.swift — render without a window, read the pixels back.
//
//  Purpose : Verification channel 1 from docs/SELF-QA-HARNESS.md, and the reason
//            Claude can check its own visual work. Any point in the graph can be
//            rendered into an offscreen texture and turned back into an ImageBuffer
//            for assertions or a PNG.
//  Inputs  : `ImageBuffer`s or `MTLTexture`s.
//  Outputs : `ImageBuffer`s (and, via SelfQACheck, PNG files).
//  Connects: MetalContext for the device/pipelines; FrameAssertions consumes what
//            this produces; the App's live renderer uses the same pipelines so the
//            offscreen result and the on-screen result come from identical shaders.
//  Extend  : add a method per graph operation you need to verify. Always route it
//            through the same pipelines the live path uses — a self-QA-only shader
//            would prove nothing about the app.
//

import Foundation
import Metal

/// Renders graph operations to an offscreen texture and reads them back to the CPU.
public final class OffscreenRenderer {
    private let context: MetalContext

    /// Staging texture for `readback`, reused across calls and rebuilt only when the
    /// geometry changes. See the note in `readback`.
    private var staging: MTLTexture?
    /// The destination bytes for `readback`, reused for the same reason.
    private var stagingBytes: [UInt8] = []

    /// Fails only when Metal itself is unavailable.
    public init?(context: MetalContext? = MetalContext.shared) {
        guard let context else {
            Log.error(.selfqa, "OffscreenRenderer needs Metal; offscreen checks cannot run")
            return nil
        }
        self.context = context
    }

    /// Reads a texture back into an `ImageBuffer`.
    ///
    /// Private-storage textures cannot be read by the CPU, so the contents are first
    /// blitted into a shared staging texture. This is the one place that dance
    /// happens; callers just get bytes.
    public func readback(_ texture: MTLTexture) -> ImageBuffer? {
        let width = texture.width
        let height = texture.height

        // THE STAGING TEXTURE AND ITS BYTES ARE CACHED, not rebuilt per call.
        //
        // Despite living under SelfQA this is on the live frame path in three places:
        // the recorder (once per armed feed) and the streamer (once per destination).
        // Recording every feed is several calls a FRAME, and each one used to allocate a
        // fresh 1.38 MB `.shared` texture plus a 1.38 MB array — roughly 400 MB/s
        // through the allocator at 29.97 fps, which is where a long run's IOSurface and
        // wired-memory fragmentation comes from.
        //
        // Cached on size, exactly the way every effect node already caches its render
        // target. Geometry is fixed in practice, so this allocates once.
        if staging?.width != width || staging?.height != height {
            let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.pixelFormat,
                width: width, height: height, mipmapped: false
            )
            stagingDescriptor.usage = [.shaderRead]
            stagingDescriptor.storageMode = .shared
            guard let texture = context.device.makeTexture(descriptor: stagingDescriptor) else {
                Log.error(.selfqa, "readback could not allocate its staging texture")
                return nil
            }
            texture.label = "readback-staging"
            staging = texture
            stagingBytes = [UInt8](
                repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        }

        guard let staging,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            Log.error(.selfqa, "readback could not set up its staging copy")
            return nil
        }
        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: staging, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.selfqa, "readback command buffer failed: \(error)")
            return nil
        }

        stagingBytes.withUnsafeMutableBytes { raw in
            staging.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * ImageBuffer.bytesPerPixel,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return ImageBuffer.fromBGRA(width: width, height: height, bgra: stagingBytes)
    }

    /// Runs one full-screen pass into a fresh render target and reads it back.
    ///
    /// - Parameters:
    ///   - pipeline: the fragment pipeline to run.
    ///   - inputs: textures bound to texture slots 0, 1, ... in order.
    ///   - scalar: an optional float bound to buffer slot 0 (the crossfade mix).
    ///   - width/height: the size of the render target.
    public func render(
        pipeline: MTLRenderPipelineState,
        inputs: [MTLTexture],
        scalar: Float? = nil,
        width: Int,
        height: Int,
        label: String = "offscreen"
    ) -> ImageBuffer? {
        guard let target = context.makeRenderTarget(width: width, height: height, label: label) else {
            return nil
        }
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            Log.error(.selfqa, "could not begin offscreen pass '\(label)'")
            return nil
        }
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
        for (slot, texture) in inputs.enumerated() {
            encoder.setFragmentTexture(texture, index: slot)
        }
        if var scalar {
            encoder.setFragmentBytes(&scalar, length: MemoryLayout<Float>.size, index: 0)
        }
        // Three vertices: the full-screen triangle generated in the vertex shader.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.selfqa, "offscreen pass '\(label)' failed: \(error)")
            return nil
        }
        return readback(target)
    }

    /// Round-trips an image through Metal unchanged. The proof-of-life check: if this
    /// does not come back identical, nothing downstream can be trusted.
    public func blit(_ image: ImageBuffer) -> ImageBuffer? {
        guard let texture = context.makeTexture(from: image, label: "blit-source") else { return nil }
        return render(
            pipeline: context.blitPipeline,
            inputs: [texture],
            width: image.width, height: image.height,
            label: "blit"
        )
    }

    /// Mixes two images the way the A/B fader does (SPEC 12), through the same
    /// pipeline the live renderer uses.
    ///
    /// - Parameter mix: 0 is entirely `a`, 1 is entirely `b`.
    public func crossfade(_ a: ImageBuffer, _ b: ImageBuffer, mix: Float) -> ImageBuffer? {
        guard let textureA = context.makeTexture(from: a, label: "crossfade-a"),
              let textureB = context.makeTexture(from: b, label: "crossfade-b") else { return nil }
        return render(
            pipeline: context.crossfadePipeline,
            inputs: [textureA, textureB],
            scalar: mix,
            width: a.width, height: a.height,
            label: "crossfade"
        )
    }
}
