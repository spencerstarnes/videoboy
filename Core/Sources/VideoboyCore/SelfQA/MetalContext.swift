//
//  MetalContext.swift — the one Metal device, queue, and shader library.
//
//  Purpose : SPEC 1 requires a single shared `MTLDevice` and command queue. This is
//            it. It also owns the shader library, compiled once from source at
//            startup so no offline .metallib has to be built and shipped.
//  Inputs  : none; discovers the system default device.
//  Outputs : `MetalContext.shared` (nil on a machine with no Metal device).
//  Connects: OffscreenRenderer (self-QA readback) and the App's live render loop.
//  Extend  : add a shader to `ShaderSource.library` and a pipeline accessor here.
//            Keep shader source in one string so a compile error names one file.
//

import Foundation
import Metal

/// Metal shader source, compiled at runtime.
///
/// Runtime compilation is deliberate: it keeps `Core` a plain SwiftPM package with
/// no build-tool plugin, and a shader error surfaces as a logged message at startup
/// instead of a build failure in a separate toolchain. The cost is a few
/// milliseconds once per process.
enum ShaderSource {
    static let library = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // A full-screen triangle. Three vertices, no vertex buffer: cheaper and simpler
    // than a quad, and it avoids a seam down the diagonal.
    vertex VertexOut fullscreen_vertex(uint vertexID [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 position = corners[vertexID];
        VertexOut out;
        out.position = float4(position, 0.0, 1.0);
        // Flip Y so texture row 0 is the top row of the image, matching ImageBuffer.
        out.uv = float2((position.x + 1.0) * 0.5, 1.0 - (position.y + 1.0) * 0.5);
        return out;
    }

    // Straight copy of one texture.
    fragment float4 blit_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return source.sample(linearSampler, in.uv);
    }

    // Linear crossfade between two textures. mix = 0 is all A, mix = 1 is all B.
    // This is the A/B and ONE/TWO fader (SPEC 12).
    fragment float4 crossfade_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> sourceA [[texture(0)]],
                                       texture2d<float> sourceB [[texture(1)]],
                                       constant float &mixAmount [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float4 a = sourceA.sample(linearSampler, in.uv);
        float4 b = sourceB.sample(linearSampler, in.uv);
        return mix(a, b, clamp(mixAmount, 0.0, 1.0));
    }
    """
}

/// Shared Metal state. One device, one queue, one library, for the whole process.
public final class MetalContext {

    /// The process-wide context, or nil if this machine exposes no Metal device.
    /// Every caller must handle nil by degrading to a labelled disabled state
    /// rather than crashing (SPEC 1.5).
    public static let shared: MetalContext? = MetalContext()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    /// Copies one texture to the render target.
    public let blitPipeline: MTLRenderPipelineState
    /// Mixes two textures by a scalar.
    public let crossfadePipeline: MTLRenderPipelineState

    /// The pixel format used everywhere in the graph. BGRA8 matches what CoreVideo
    /// hands back from capture and what a `CAMetalLayer` wants to present, so the
    /// common paths need no conversion.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.error(.render, "no Metal device available; all rendering is disabled")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            Log.error(.render, "could not create a Metal command queue on \(device.name)")
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.library, options: nil)
        } catch {
            Log.error(.render, "shader library failed to compile: \(error)")
            return nil
        }

        func makePipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = MetalContext.pixelFormat
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                Log.error(.render, "pipeline \(fragment) failed: \(error)")
                return nil
            }
        }

        guard let blit = makePipeline(vertex: "fullscreen_vertex", fragment: "blit_fragment"),
              let crossfade = makePipeline(vertex: "fullscreen_vertex", fragment: "crossfade_fragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.blitPipeline = blit
        self.crossfadePipeline = crossfade
        Log.info(.render, "Metal ready on \(device.name)")
    }

    /// Creates a texture suitable for both sampling and rendering into.
    public func makeRenderTarget(width: Int, height: Int, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.pixelFormat,
            width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Log.error(.render, "could not allocate \(width)x\(height) render target '\(label)'")
            return nil
        }
        texture.label = label
        return texture
    }

    /// Uploads an `ImageBuffer` into a new sampleable texture.
    ///
    /// `ImageBuffer` is RGBA and the graph is BGRA, so channels are swapped during
    /// the copy. Doing it here keeps every other call site free of the question.
    public func makeTexture(from image: ImageBuffer, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.pixelFormat,
            width: image.width, height: image.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Log.error(.render, "could not allocate texture '\(label)'")
            return nil
        }
        texture.label = label

        var bgra = image.pixels
        for index in stride(from: 0, to: bgra.count, by: ImageBuffer.bytesPerPixel) {
            bgra.swapAt(index, index + 2)
        }
        bgra.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: image.bytesPerRow
            )
        }
        return texture
    }
}
