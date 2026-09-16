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

    // ---------------------------------------------------------------------------
    // NTSC composite codec (SPEC 9).
    //
    // This is a REAL SIGNAL MODEL, not a look-alike filter: the picture is encoded
    // to a composite waveform and decoded back, and the artefacts fall out of that
    // round trip rather than being drawn on.
    //
    //   encode:  RGB -> YIQ, then S(x) = Y + I*cos(phase) + Q*sin(phase)
    //   decode:  low-pass S for luma; multiply by cos/sin and low-pass for chroma
    //
    // Because one wire carries both, luma detail near the subcarrier frequency
    // decodes as colour (rainbowing) and chroma leaks into luma (dot crawl). The
    // subcarrier phase advances along the line, inverts every line, and steps every
    // frame, which is exactly what makes dot crawl crawl.
    // ---------------------------------------------------------------------------

    struct CompositeParams {
        float phasePerPixel;     // subcarrier radians per pixel
        float phasePerLine;      // radians added per scanline
        float phasePerFrame;     // radians added per frame
        float frameIndex;
        float lumaBandwidth;     // 0..1, how much luma detail survives
        float chromaBleed;       // 0..1, how far chroma smears along the line
        float crawl;             // 0..1, strength of the cross-luma artefact
        float wobble;            // 0..1, TBC line jitter
        float headSwitching;     // 0..1, noise band height at the bottom
        float chromaSubsample;   // 1 = 4:4:4, 2 = 4:2:2, 4 = 4:1:1
        float sVideo;            // 1 = S-Video (separate Y/C), 0 = composite
        float width;
        float height;
    };

    static inline float3 rgbToYIQ(float3 c) {
        // FCC NTSC matrix.
        return float3(
            0.299 * c.r + 0.587 * c.g + 0.114 * c.b,
            0.596 * c.r - 0.274 * c.g - 0.322 * c.b,
            0.211 * c.r - 0.523 * c.g + 0.312 * c.b
        );
    }

    static inline float3 yiqToRGB(float3 yiq) {
        return float3(
            yiq.x + 0.956 * yiq.y + 0.619 * yiq.z,
            yiq.x - 0.272 * yiq.y - 0.647 * yiq.z,
            yiq.x - 1.106 * yiq.y + 1.703 * yiq.z
        );
    }

    fragment float4 composite_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       constant CompositeParams &p [[buffer(0)]]) {
        constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

        float2 texel = float2(1.0 / p.width, 1.0 / p.height);
        float line = floor(in.uv.y * p.height);

        // TBC: each line is displaced horizontally. A real time-base error is not
        // white noise, so this is a couple of incommensurate sines plus a per-line
        // hash, which reads as a wobble rather than as static.
        float jitterHash = fract(sin(line * 12.9898 + p.frameIndex * 78.233) * 43758.5453);
        float jitter = (sin(line * 0.31 + p.frameIndex * 0.21) * 0.6
                        + sin(line * 1.13 + p.frameIndex * 0.07) * 0.4
                        + (jitterHash - 0.5) * 0.5) * p.wobble * 0.01;

        // Head-switching: the bottom few lines of a helical-scan tape are torn,
        // because the heads swap there. Displacement grows toward the last line.
        float bandStart = 1.0 - 0.035 * p.headSwitching;
        if (p.headSwitching > 0.001 && in.uv.y > bandStart) {
            float depth = (in.uv.y - bandStart) / max(1.0 - bandStart, 1e-5);
            jitter += depth * depth * 0.06 * p.headSwitching
                    + (jitterHash - 0.5) * 0.02 * p.headSwitching;
        }

        float phaseBase = line * p.phasePerLine + p.frameIndex * p.phasePerFrame;

        // Sampling the composite signal either side of this pixel is what makes the
        // filtering real: the decoder can only separate luma from chroma by looking
        // along the line, exactly as hardware does.
        const int taps = 6;
        float lumaSum = 0.0;
        float weightSum = 0.0;
        float iSum = 0.0;
        float qSum = 0.0;
        float chromaWeightSum = 0.0;

        // Chroma has far less bandwidth than luma, so its impulse response is much
        // wider. Rather than spend taps on that, the chroma taps are SPREAD further
        // apart than the luma ones — same cost, much longer smear, and it is the
        // right shape: a narrower filter in frequency is a wider one in space.
        float chromaSpread = mix(1.0, 5.0, p.chromaBleed);

        for (int t = -taps; t <= taps; ++t) {
            float offset = float(t);
            float x = in.uv.x + offset * texel.x + jitter;
            float2 uv = float2(x, in.uv.y);
            float2 chromaTapUV = float2(in.uv.x + offset * chromaSpread * texel.x + jitter, in.uv.y);

            // Chroma subsampling happens before encoding: DV is 4:1:1 on NTSC, and
            // leaning into that is the point (SPEC 9).
            float2 chromaUV = chromaTapUV;
            if (p.chromaSubsample > 1.5) {
                float block = p.chromaSubsample * texel.x;
                chromaUV.x = (floor(chromaTapUV.x / block) + 0.5) * block;
            }

            float3 sampleYIQ = rgbToYIQ(source.sample(pointSampler, uv).rgb);
            float3 chromaYIQ = rgbToYIQ(source.sample(pointSampler, chromaUV).rgb);
            sampleYIQ.yz = chromaYIQ.yz;

            float phase = phaseBase + (in.uv.x * p.width + offset) * p.phasePerPixel;

            // The composite waveform: one wire carrying luma and modulated chroma.
            float signal = sampleYIQ.x
                         + sampleYIQ.y * cos(phase)
                         + sampleYIQ.z * sin(phase);

            // On the S-Video path luma and chroma travel separately, so the decoder
            // never has to separate them and the cross artefacts simply do not exist.
            float decodedLuma = mix(signal, sampleYIQ.x, p.sVideo);

            // Luma low-pass. A narrower window keeps more detail; a wider one is a
            // softer, lower-bandwidth picture with more ringing.
            float lumaSigma = mix(0.6, 3.0, 1.0 - p.lumaBandwidth);
            float lumaWeight = exp(-(offset * offset) / (2.0 * lumaSigma * lumaSigma));
            lumaSum += decodedLuma * lumaWeight;
            weightSum += lumaWeight;

            // Chroma demodulation, then its own low-pass.
            float chromaSigma = 3.0;
            float chromaWeight = exp(-(offset * offset) / (2.0 * chromaSigma * chromaSigma));
            // The chroma being demodulated is the one sampled at the spread offset,
            // which is what carries the colour past a hard edge.
            float chromaPhase = phaseBase + (in.uv.x * p.width + offset * chromaSpread) * p.phasePerPixel;
            float chromaSignal = sampleYIQ.x
                               + sampleYIQ.y * cos(chromaPhase)
                               + sampleYIQ.z * sin(chromaPhase);
            float demodSource = mix(chromaSignal,
                                    sampleYIQ.y * cos(chromaPhase) + sampleYIQ.z * sin(chromaPhase),
                                    p.sVideo);
            float phaseForDemod = chromaPhase;
            iSum += demodSource * cos(phaseForDemod) * chromaWeight;
            qSum += demodSource * sin(phaseForDemod) * chromaWeight;
            chromaWeightSum += chromaWeight;
        }

        float y = lumaSum / max(weightSum, 1e-5);
        // The factor of two undoes the averaging of the product of two sinusoids.
        float i = 2.0 * iSum / max(chromaWeightSum, 1e-5);
        float q = 2.0 * qSum / max(chromaWeightSum, 1e-5);

        // Dot crawl: on the composite path the residual subcarrier left in luma is
        // visible as a crawling dot pattern. Scaling it is what the crawl control does.
        if (p.sVideo < 0.5) {
            float phaseHere = phaseBase + in.uv.x * p.width * p.phasePerPixel;
            float residual = (i * cos(phaseHere) + q * sin(phaseHere));
            y += residual * 0.25 * p.crawl;
        }

        float3 rgb = yiqToRGB(float3(y, i, q));
        return float4(clamp(rgb, 0.0, 1.0), 1.0);
    }

    // ---------------------------------------------------------------------------
    // Echo / trails (SPEC 9).
    //
    // BEHAVIOURAL EMULATION, not a signal model: this is the VDMX-style frame-history
    // echo, where each frame is mixed over a decaying accumulation of the ones before
    // it. A phosphor-persistence model would decay non-linearly per channel; this
    // does not claim to be one.
    // ---------------------------------------------------------------------------

    struct EchoParams {
        float decay;      // 0..1, how much of the history survives each frame
        float threshold;  // 0..1, luma below this does not echo at all
        float gain;       // 0..1, how strongly the echo shows
    };

    static inline float lumaOf(float3 c) {
        return dot(c, float3(0.299, 0.587, 0.114));
    }

    fragment float4 echo_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> current [[texture(0)]],
                                  texture2d<float> history [[texture(1)]],
                                  constant EchoParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float3 now = current.sample(linearSampler, in.uv).rgb;
        float3 past = history.sample(linearSampler, in.uv).rgb;

        // A luma key decides what trails at all: only bright enough pixels leave a
        // tail, which is what keeps the effect from turning the whole frame to mud.
        float key = step(p.threshold, lumaOf(now));

        // The accumulation: this frame's keyed contribution, or the decayed history,
        // whichever is brighter. `max` rather than a sum so trails glow behind the
        // picture and settle, instead of clipping to white as they pile up.
        float3 accumulated = max(now * key, past * p.decay);

        // The output is the live picture with the trail showing through behind it.
        float3 result = max(now, accumulated * p.gain);
        return float4(clamp(result, 0.0, 1.0), 1.0);
    }

    // ---------------------------------------------------------------------------
    // Feedback (SPEC 10).
    //
    // The classic infinite tunnel: the previous output, zoomed and rotated a little,
    // mixed back under the current frame. Internal (texture) feedback; the external
    // path through a capture device reuses the same shader with the captured frame
    // standing in for the history texture.
    // ---------------------------------------------------------------------------

    struct FeedbackParams {
        float gain;       // 0..1, how much of the loop returns
        float zoom;       // 1.0 is no zoom; >1 pushes inward
        float rotate;     // turns
        float threshold;  // luma key on what re-enters the loop
    };

    fragment float4 feedback_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> current [[texture(0)]],
                                      texture2d<float> history [[texture(1)]],
                                      constant FeedbackParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

        // Transform about the centre, so the tunnel recedes to the middle.
        float2 centred = in.uv - 0.5;
        float angle = p.rotate * 6.28318530718;
        float c = cos(angle);
        float s = sin(angle);
        float2 rotated = float2(centred.x * c - centred.y * s, centred.x * s + centred.y * c);
        float2 sampleUV = rotated / max(p.zoom, 0.01) + 0.5;

        float3 now = current.sample(linearSampler, in.uv).rgb;

        // Outside the frame there is nothing to feed back; clamping would smear the
        // edge pixel inward forever, which reads as a stuck border.
        float3 fed = float3(0.0);
        if (all(sampleUV > float2(0.0)) && all(sampleUV < float2(1.0))) {
            fed = history.sample(linearSampler, sampleUV).rgb;
            fed *= step(p.threshold, lumaOf(fed));
        }

        // Screen blend rather than a plain sum. A sum compounds every frame — at any
        // useful gain the geometric series diverges and the picture clips to flat
        // white within a second, which is not a look, it is a loss of the image.
        // Screen is bounded to 1 by construction and is what optical feedback
        // actually does: light adding to light, with diminishing returns as it
        // approaches full brightness. It still blooms; it just cannot destroy itself.
        float3 loop = clamp(fed * p.gain, 0.0, 1.0);
        float3 result = 1.0 - (1.0 - now) * (1.0 - loop);
        return float4(clamp(result, 0.0, 1.0), 1.0);
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
    /// NTSC composite encode/decode round trip.
    public let compositePipeline: MTLRenderPipelineState
    /// Echo/trails: blends a frame with the decaying history behind it.
    public let echoPipeline: MTLRenderPipelineState
    /// Feedback: the previous output, transformed, mixed back in.
    public let feedbackPipeline: MTLRenderPipelineState

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
              let crossfade = makePipeline(vertex: "fullscreen_vertex", fragment: "crossfade_fragment"),
              let composite = makePipeline(vertex: "fullscreen_vertex", fragment: "composite_fragment"),
              let echo = makePipeline(vertex: "fullscreen_vertex", fragment: "echo_fragment"),
              let feedback = makePipeline(vertex: "fullscreen_vertex", fragment: "feedback_fragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.blitPipeline = blit
        self.crossfadePipeline = crossfade
        self.compositePipeline = composite
        self.echoPipeline = echo
        self.feedbackPipeline = feedback
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

    /// Blends a processed texture back over the original by a wet/dry amount.
    ///
    /// Every effect needs this and the arithmetic is identical for all of them, so it
    /// lives here rather than being written out three times. It reuses the crossfade
    /// pipeline, which means the Wet/Dry slider and the A/B fader are demonstrably
    /// the same operation.
    ///
    /// - Parameter amount: 0 is entirely dry (the original), 1 is entirely wet.
    /// - Returns: false if the blend could not be encoded, in which case the caller
    ///   should fall back to whichever texture it already has.
    public func blend(
        dry: MTLTexture, wet: MTLTexture, amount: Double, into target: MTLTexture, label: String
    ) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(label) could not encode its wet/dry blend")
            return false
        }
        encoder.label = "\(label)-wetdry"
        encoder.setRenderPipelineState(crossfadePipeline)
        encoder.setFragmentTexture(dry, index: 0)
        encoder.setFragmentTexture(wet, index: 1)
        var mix = Float(min(max(amount, 0), 1))
        encoder.setFragmentBytes(&mix, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(label) wet/dry blend failed: \(error)")
            return false
        }
        return true
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
