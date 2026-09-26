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

    // A source picture placed inside the canvas: fitted, filled or stretched, and
    // turned upright. `origin`/`size` are the picture's rectangle in canvas UV; outside
    // it is black, which is what goes to air. `quarterTurns` rotates clockwise for
    // display (a phone's portrait clip is stored landscape with a rotation flag).
    struct FitParams {
        float2 origin;
        float2 size;
        int quarterTurns;
    };

    fragment float4 fit_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 constant FitParams &params [[buffer(0)]]) {
        float2 d = (in.uv - params.origin) / params.size;
        if (d.x < 0.0 || d.x > 1.0 || d.y < 0.0 || d.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 s = d;
        switch (params.quarterTurns & 3) {
            case 1: s = float2(d.y, 1.0 - d.x); break;
            case 2: s = float2(1.0 - d.x, 1.0 - d.y); break;
            case 3: s = float2(1.0 - d.y, d.x); break;
            default: break;
        }
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return source.sample(linearSampler, s);
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
    // Transform: scale, rotate, flip.
    //
    // Sampling runs BACKWARDS, which is the whole trick and the thing to understand
    // before editing it. For each output pixel this asks "where in the SOURCE did
    // this come from", so the transform applied to the coordinate is the INVERSE of
    // the transform you see on screen: to make the picture twice as big, sample half
    // as far from the centre.
    //
    // Everything happens about the centre, because a video frame rotated about its
    // corner leaves the screen.
    // ---------------------------------------------------------------------------

    struct TransformParams {
        float scale;        // 0.1..4, 1 is unchanged
        float rotation;     // turns, 0..1
        float flipH;        // 0 or 1
        float flipV;        // 0 or 1
        float offsetX;      // -1..1 of the frame width, 0 is centred
        float offsetY;      // -1..1 of the frame height
    };

    fragment float4 transform_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       constant TransformParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

        float2 centred = in.uv - 0.5;

        // Flips first, and they are their own inverse, so no special care needed.
        if (p.flipH > 0.5) { centred.x = -centred.x; }
        if (p.flipV > 0.5) { centred.y = -centred.y; }

        // Inverse rotation: negative angle.
        float angle = -p.rotation * 6.28318530718;
        float c = cos(angle);
        float s = sin(angle);
        float2 rotated = float2(centred.x * c - centred.y * s,
                                centred.x * s + centred.y * c);

        // Inverse scale: divide.
        float2 sampleUV = rotated / max(p.scale, 0.01) + 0.5;

        // Inverse offset: SUBTRACT, because this is a backward map. The shader is asked
        // "which source pixel belongs here", so moving the picture right means reading
        // from further left. Adding here would move it the wrong way, which is the kind
        // of thing that reads as the control being inverted rather than wrong.
        sampleUV -= float2(p.offsetX, p.offsetY);

        // Outside the frame is BLACK, not the clamped edge pixel. Clamping smears the
        // border outward into a streaked mess, which reads as a broken render rather
        // than as a picture that has been scaled down.
        if (any(sampleUV < float2(0.0)) || any(sampleUV > float2(1.0))) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        return float4(source.sample(linearSampler, sampleUV).rgb, 1.0);
    }

    // ---------------------------------------------------------------------------
    // Colour controls.
    //
    // The ordinary grade stage every mixer has, in the order a grade is actually
    // applied. Order matters and is not arbitrary:
    //
    //   1. LEVELS   — black and white points remap the input range first, because
    //                 everything after them should work on a normalised signal.
    //   2. GAMMA    — midtone curve, applied while the range is still 0..1.
    //   3. SHADOW / HIGHLIGHT — selective lift and roll-off, weighted so each end
    //                 moves without dragging the other with it.
    //   4. CONTRAST — pivoted about mid grey, not about zero, so raising contrast
    //                 does not also darken the whole picture.
    //   5. BRIGHTNESS — a straight offset, last, so it is predictable.
    //   6. SATURATION — about luma, so a desaturated picture keeps its brightness.
    //
    // Everything is clamped at the end. This chain feeds an analog output where
    // out-of-range values are not merely ugly, they are unencodable.
    // ---------------------------------------------------------------------------

    struct ColourParams {
        float brightness;   // -1..1, added
        float contrast;     // 0..2, 1 is unchanged
        float saturation;   // 0..2, 1 is unchanged
        float shadow;       // -1..1, lifts or crushes the dark end
        float highlight;    // -1..1, lifts or rolls off the bright end
        float blackLevel;   // 0..1, input level remapped to 0
        float whiteLevel;   // 0..1, input level remapped to 1
        float gamma;        // 0.1..4, 1 is unchanged
    };

    fragment float4 colour_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    constant ColourParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float3 c = source.sample(linearSampler, in.uv).rgb;

        // 1. Levels. A white point at or below the black point would divide by zero
        //    or invert the picture; the span is floored rather than left to chance.
        float span = max(p.whiteLevel - p.blackLevel, 0.001);
        c = clamp((c - p.blackLevel) / span, 0.0, 1.0);

        // 2. Gamma.
        c = pow(c, float3(1.0 / max(p.gamma, 0.01)));

        // 3. Shadows and highlights, each weighted to its own end of the range so
        //    lifting the shadows leaves the highlights where they were.
        float luma = lumaOf(c);
        float shadowWeight = 1.0 - smoothstep(0.0, 0.5, luma);
        float highlightWeight = smoothstep(0.5, 1.0, luma);
        c += p.shadow * shadowWeight * 0.5;
        c += p.highlight * highlightWeight * 0.5;
        c = clamp(c, 0.0, 1.0);

        // 4. Contrast about mid grey.
        c = (c - 0.5) * p.contrast + 0.5;

        // 5. Brightness.
        c += p.brightness;

        // 6. Saturation about luma, so brightness survives desaturation.
        float grey = lumaOf(clamp(c, 0.0, 1.0));
        c = mix(float3(grey), c, p.saturation);

        return float4(clamp(c, 0.0, 1.0), 1.0);
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
        // MULTIPLY, not divide. Sampling farther from the centre than the pixel
        // being written means each pass pulls the picture INWARD, which is the
        // tunnel this is named for. Dividing magnifies the history instead and
        // pushes the image off the edges — the opposite of what the comment above,
        // the parameter's documentation and the test all say this does. It went
        // unnoticed because the history buffer was never cleared, so the centre of
        // the frame was full of uninitialised memory that read as "light arriving".
        float2 sampleUV = rotated * max(p.zoom, 0.01) + 0.5;

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

    // ---------------------------------------------------------------------------
    // Generators (SPEC 6A).
    //
    // No-input producers. One shader with a mode switch rather than a dozen tiny
    // pipelines: they share all their plumbing and differ only in a few lines each,
    // so a dozen pipelines would be a dozen places to keep in step.
    // ---------------------------------------------------------------------------

    struct GeneratorParams {
        int mode;
        float scale;     // 0..1, size of the feature (cells, stripes, noise scale)
        float phase;     // 0..1, animation position — usually driven by an LFO
        float amount;    // 0..1, mode-specific: octaves, line weight, duty
        float4 colorA;
        float4 colorB;
        float width;
        float height;
    };

    // A cheap stable hash. Deterministic for a coordinate, which is what lets a noise
    // field be re-evaluated at any time without keeping state.
    static inline float hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    // Value noise: hashed lattice with a smoothstep between the corners.
    static inline float valueNoise(float2 p) {
        float2 cell = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(cell);
        float b = hash21(cell + float2(1.0, 0.0));
        float c = hash21(cell + float2(0.0, 1.0));
        float d = hash21(cell + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    // Fractal noise: octaves of value noise at halving amplitude. `turbulent` takes
    // the absolute value of each octave about zero, which is what produces the
    // creased "difference clouds" look rather than smooth cloud.
    static inline float fractalNoise(float2 p, int octaves, bool turbulent) {
        float sum = 0.0;
        float amplitude = 0.5;
        float total = 0.0;
        for (int i = 0; i < octaves; ++i) {
            float n = valueNoise(p);
            if (turbulent) { n = abs(n * 2.0 - 1.0); }
            sum += n * amplitude;
            total += amplitude;
            p *= 2.0;
            amplitude *= 0.5;
        }
        return total > 0.0 ? sum / total : 0.0;
    }

    fragment float4 generator_fragment(VertexOut in [[stage_in]],
                                       constant GeneratorParams &p [[buffer(0)]]) {
        float2 uv = in.uv;
        // Correct for the 4:3 frame so circles are round and cells are square.
        float aspect = p.width / max(p.height, 1.0);
        float2 centred = float2((uv.x - 0.5) * aspect, uv.y - 0.5);

        float3 a = p.colorA.rgb;
        float3 b = p.colorB.rgb;
        float t = 0.0;

        switch (p.mode) {
            case 0:  // solid
                t = 0.0;
                break;
            case 1: { // linear gradient, angle from phase
                float angle = p.phase * 6.28318530718;
                float2 direction = float2(cos(angle), sin(angle));
                t = clamp(dot(centred, direction) + 0.5, 0.0, 1.0);
                break;
            }
            case 2: { // radial gradient
                t = clamp(length(centred) / max(p.scale, 0.01), 0.0, 1.0);
                break;
            }
            case 3: { // checkerboard
                float cells = mix(2.0, 64.0, p.scale);
                float2 grid = floor((uv + p.phase) * cells);
                t = fmod(grid.x + grid.y, 2.0);
                break;
            }
            case 4: { // stripes, angle from amount
                float angle = p.amount * 3.14159265359;
                float2 direction = float2(cos(angle), sin(angle));
                float bands = mix(2.0, 80.0, p.scale);
                t = step(0.5, fract(dot(centred, direction) * bands + p.phase));
                break;
            }
            case 5: { // grid / crosshatch
                float spacing = mix(4.0, 64.0, p.scale);
                float weight = mix(0.02, 0.3, p.amount);
                float2 g = fract((uv + p.phase) * spacing);
                t = (min(g.x, 1.0 - g.x) < weight || min(g.y, 1.0 - g.y) < weight) ? 1.0 : 0.0;
                break;
            }
            case 6: { // concentric rings / target
                float rings = mix(2.0, 40.0, p.scale);
                t = step(0.5, fract(length(centred) * rings - p.phase));
                break;
            }
            case 7: { // white noise — reseeded by phase so it can crackle on a beat
                t = hash21(uv * float2(p.width, p.height) + p.phase * 1000.0);
                break;
            }
            case 8: { // smooth noise field, drifting with phase
                float scale = mix(2.0, 40.0, p.scale);
                t = valueNoise(uv * scale + float2(p.phase * 4.0, p.phase * 2.0));
                break;
            }
            case 9: { // difference clouds / plasma
                int octaves = int(mix(1.0, 6.0, p.amount));
                float scale = mix(1.0, 12.0, p.scale);
                t = fractalNoise(uv * scale + p.phase * 2.0, octaves, true);
                break;
            }
            case 10: { // dot / halftone field
                float cells = mix(4.0, 80.0, p.scale);
                float2 cell = fract(uv * cells) - 0.5;
                float radius = mix(0.05, 0.5, p.amount);
                t = 1.0 - smoothstep(radius - 0.05, radius, length(cell));
                break;
            }
            case 11: { // scanline / CRT bar
                float lines = mix(20.0, float(p.height), p.scale);
                t = step(0.5, fract(uv.y * lines + p.phase));
                break;
            }
            default:
                t = 0.0;
                break;
        }

        return float4(clamp(mix(a, b, clamp(t, 0.0, 1.0)), 0.0, 1.0), 1.0);
    }

    // ---------------------------------------------------------------------------
    // Layer compositing (SPEC 12).
    //
    // ONE is A over B, TWO is C over D, PRIMARY is ONE over TWO. Each composite has
    // a blend mode and a per-layer opacity, and the fader still crossfades between
    // the two layers — so the fader and the blend mode are independent controls,
    // which is what makes "screen at 40%" expressible.
    //
    // The mode numbers here must match the BlendMode enum in Swift. They are a
    // contiguous range so the Swift side can map a 0..1 parameter onto them.
    // ---------------------------------------------------------------------------

    struct BlendParams {
        float mixAmount;    // the crossfader: 0 = pure base, 0.5 = full blend, 1 = pure blend layer
        float opacity;      // retained for template compatibility; see the note below
        int mode;           // which blend function
        float keyR;         // key colour (6xE) — only read when mode is Key
        float keyG;
        float keyB;
        float keyThreshold;  // RGB distance below which a pixel is "the background"
        float keyEdge;       // width of the soft transition past that distance
        int transition;      // which pattern the fader's move follows — see Transition.swift
        // The AVE-5 wipe block (AVE5Wipe.swift), read only when transition is 12.
        int ave5Keys;        // lit pattern keys, AVE5Wipe.PatternKeys bits
        int ave5Tiles;       // MULTI: tiles per side, 1 / 2 / 4
        int ave5Edge;        // WIPE: 0 normal, 1 border, 2 soft
        int ave5Reversed;    // REVERSE, flipped again by ONE-WAY on the trip back
        float ave5CentreX;   // joystick positioner, 0...1 within a tile
        float ave5CentreY;
        float ave5BorderR;   // BACK COLOUR, for the border edge
        float ave5BorderG;
        float ave5BorderB;
    };

    static inline float3 blendChannelwise(int mode, float3 base, float3 blend) {
        switch (mode) {
            case 0:  return blend;                                   // normal
            case 1:  return base * blend;                            // multiply
            case 2:  return 1.0 - (1.0 - base) * (1.0 - blend);      // screen
            case 3:  // overlay — multiply on dark base, screen on light
                return select(1.0 - 2.0 * (1.0 - base) * (1.0 - blend),
                              2.0 * base * blend,
                              base < 0.5);
            case 4:  return max(base, blend);                        // lighten
            case 5:  return min(base, blend);                        // darken
            case 6:  return abs(base - blend);                       // difference
            case 7:  return min(base + blend, 1.0);                  // add
            case 8:  return max(base - blend, 0.0);                  // subtract
            case 9:  // colour dodge — brighten base by blend
                return select(min(base / max(1.0 - blend, 1e-4), 1.0),
                              float3(1.0),
                              blend >= 1.0);
            case 10: // colour burn — darken base by blend
                return select(1.0 - min((1.0 - base) / max(blend, 1e-4), 1.0),
                              float3(0.0),
                              blend <= 0.0);
            case 11: // hard light — overlay with the layers swapped
                return select(1.0 - 2.0 * (1.0 - base) * (1.0 - blend),
                              2.0 * base * blend,
                              blend < 0.5);
            case 12: { // soft light — a gentler overlay
                float3 d = select(sqrt(base), ((16.0 * base - 12.0) * base + 4.0) * base,
                                  base < 0.25);
                return select(base + (2.0 * blend - 1.0) * (d - base),
                              base - (1.0 - 2.0 * blend) * base * (1.0 - base),
                              blend < 0.5);
            }
            default: return blend;
        }
    }

    /* Genlock/chroma key (SPEC 18.2). Not a case in `blendChannelwise` — a key
     * needs three extra parameters (colour, threshold, edge) that function's
     * (mode, base, blend) shape has no room for, so it is a sibling function
     * instead, called directly from `composite_blend_fragment`.
     *
     * `blend` is the upper/key layer (where the emulated titler or any other
     * keyable source is expected to sit — see CrossfadeNode's header). Its
     * distance from `keyColour` in RGB decides how much of `base` shows through:
     * close to the key colour is background and drops out entirely, far from it
     * is the title and stays fully opaque. `smoothstep` rather than a hard cutoff
     * because the source has usually been through CompositeCodecNode's dot crawl
     * and chroma bleed by the time it gets here — a bitmap font's edges are not
     * clean pixels by then, and a binary key would fringe visibly on every one.
     */
    static inline float3 keyComposite(
        float3 base, float3 blend, float3 keyColour, float threshold, float edge) {
        float dist = length(blend - keyColour);
        float alpha = smoothstep(threshold, threshold + max(edge, 0.0001), dist);
        return mix(base, blend, alpha);
    }

    struct ScopeOverlayParams {
        float2 origin;   // where the scope sits, in 0...1 of the frame
        float2 size;
        float opacity;   // how strongly the trace is added
        float dim;       // how far the picture behind it is held back
        float2 textOrigin; // the data-burn text block, in 0...1 of the frame
        float2 textSize;
        float hasScope;  // 1 when texture(1) is a scope, 0 when it is a placeholder
        float hasText;   // 1 when texture(2) is text, 0 when it is a placeholder
    };

    /* Composites a scope over the picture.
     *
     * SCREEN, not mix. A scope is a light trace on black, so screening adds the trace
     * and leaves the black doing nothing — which means the picture shows through the
     * empty parts of the graticule for free. Mixing would grey the whole rectangle
     * down towards the scope's black background instead.
     */
    fragment float4 scope_overlay_fragment(VertexOut in [[stage_in]],
                                           texture2d<float> picture [[texture(0)]],
                                           texture2d<float> scope [[texture(1)]],
                                           texture2d<float> text [[texture(2)]],
                                           constant ScopeOverlayParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float3 result = picture.sample(linearSampler, in.uv).rgb;

        float2 local = (in.uv - p.origin) / max(p.size, float2(0.0001));
        if (p.hasScope > 0.5 && all(local >= 0.0) && all(local <= 1.0)) {
            float3 trace = scope.sample(linearSampler, local).rgb;
            float3 behind = result * (1.0 - clamp(p.dim, 0.0, 1.0));
            result = 1.0 - (1.0 - behind) * (1.0 - trace * clamp(p.opacity, 0.0, 1.0));
        }

        /* The text is OVER, not screen: its backing box has to be able to darken the
         * picture, and screening black does nothing. Premultiplied, as CoreGraphics
         * draws it. Nearest sampling: the block is drawn at frame resolution and
         * placed on whole pixels, so 1:1 is exact and linear would only soften it. */
        constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
        float2 textLocal = (in.uv - p.textOrigin) / max(p.textSize, float2(0.0001));
        if (p.hasText > 0.5 && all(textLocal >= 0.0) && all(textLocal <= 1.0)) {
            float4 letters = text.sample(nearestSampler, textLocal);
            result = letters.rgb + result * (1.0 - letters.a);
        }
        return float4(clamp(result, 0.0, 1.0), 1.0);
    }

    /* Transition patterns (Transition.swift). Mode numbers must match that enum.
     *
     * Every pattern answers three questions for one pixel at fader position t:
     *   - is the incoming (right) source here yet?      → `inside`, 0 or 1
     *   - where in the right source should it be read?  → `blendUV`
     *   - where in the left source should it be read?   → `baseUV`
     * Only slide and push move a picture, so for the rest both UVs stay put.
     *
     * The contract that makes these safe to put on a crossfader: at t = 0 no pixel
     * is inside, at t = 1 every pixel is, and at t = 1 `blendUV` is `uv` — so both
     * ends of the fader are the two sources untouched, exactly as with a dissolve.
     * Hard edges on purpose: that is what an MX-1 wipe looks like, and a soft edge
     * would blur the interlace patterns into a dissolve.
     */
    struct TransitionSample {
        float inside;
        float2 baseUV;
        float2 blendUV;
    };

    // The interlace-vertical band width, in output pixels. One pixel columns would
    // turn to chroma mush through the composite codec; 16 is wide enough to survive
    // it and narrow enough to still read as a comb at 720 across. (Interlace
    // horizontal uses single scan lines on purpose — that is the field shimmer.)
    constant float kInterlaceBandPixels = 16.0;

    static inline TransitionSample transitionMask(
        int pattern, float t, float2 uv, float2 pixel, float aspect) {
        TransitionSample s;
        s.inside = 0.0;
        s.baseUV = uv;
        s.blendUV = uv;
        switch (pattern) {
            case 1:  // wipe horizontal — edge travels left to right
                s.inside = uv.x < t ? 1.0 : 0.0;
                break;
            case 2:  // wipe vertical — edge travels top to bottom
                s.inside = uv.y < t ? 1.0 : 0.0;
                break;
            case 3:  // slide horizontal — right source enters from the left, over A
                s.inside = uv.x < t ? 1.0 : 0.0;
                s.blendUV = float2(uv.x - t + 1.0, uv.y);
                break;
            case 4:  // slide vertical — enters from the top
                s.inside = uv.y < t ? 1.0 : 0.0;
                s.blendUV = float2(uv.x, uv.y - t + 1.0);
                break;
            case 5:  // push horizontal — as slide, and A is shoved out to the right
                s.inside = uv.x < t ? 1.0 : 0.0;
                s.blendUV = float2(uv.x - t + 1.0, uv.y);
                if (s.inside < 0.5) { s.baseUV = float2(uv.x - t, uv.y); }
                break;
            case 6:  // push vertical
                s.inside = uv.y < t ? 1.0 : 0.0;
                s.blendUV = float2(uv.x, uv.y - t + 1.0);
                if (s.inside < 0.5) { s.baseUV = float2(uv.x, uv.y - t); }
                break;
            case 7: {  // iris — a true circle on the output, reaching the corners at t = 1
                float2 d = (uv - 0.5) * float2(aspect, 1.0);
                float cornerRadius = length(float2(aspect, 1.0) * 0.5);
                s.inside = length(d) < t * cornerRadius ? 1.0 : 0.0;
                break;
            }
            case 8:  // split horizontal — doors part from a vertical centre line
                s.inside = abs(uv.x - 0.5) < t * 0.5 ? 1.0 : 0.0;
                break;
            case 9:  // split vertical — doors part from a horizontal centre line
                s.inside = abs(uv.y - 0.5) < t * 0.5 ? 1.0 : 0.0;
                break;
            case 10: {  // interlace horizontal — even lines L→R, odd lines R→L
                bool odd = (int(floor(pixel.y)) & 1) == 1;
                s.inside = (odd ? uv.x > 1.0 - t : uv.x < t) ? 1.0 : 0.0;
                break;
            }
            case 11: {  // interlace vertical — even bands down, odd bands up
                bool odd = (int(floor(pixel.x / kInterlaceBandPixels)) & 1) == 1;
                s.inside = (odd ? uv.y > 1.0 - t : uv.y < t) ? 1.0 : 0.0;
                break;
            }
            default:
                break;
        }
        return s;
    }

    /* The Panasonic WJ-AVE5's wipe generator. AVE5Wipe.swift has the manual's table
     * and how its five keys combine; this is that, per pixel.
     *
     * Every combination is one scalar FIELD over the screen: 0 where B arrives first,
     * 1 where it arrives last. The fader is a threshold swept through it, so the
     * contract every other transition keeps still holds — nothing at t = 0,
     * everything at t = 1, whatever keys are lit, wherever the joystick is.
     *
     *   an edge key       a ramp across its axis
     *   both of an axis   the ramp folded at the centre (B opens from the middle)
     *   no circle         the LARGER of the two axes  → boxes
     *   with circle       the SUM of the two axes     → diagonals, triangles, diamond
     *   circle alone      distance from the centre    → a round circle
     *
     * Each field is divided by its largest value over the tile's corners, edge
     * midpoints and centre (every field here is piecewise linear or a distance,
     * folded only at the middle, so its maximum is at one of those nine points), which is what lets the joystick push a
     * circle off-centre and still have it cover the screen exactly at the end of
     * travel.
     */

    // Pattern key bits — must match AVE5Wipe.PatternKeys.
    constant int kAVE5FromRight = 1;
    constant int kAVE5FromLeft = 2;
    constant int kAVE5FromBottom = 4;
    constant int kAVE5FromTop = 8;
    constant int kAVE5Circle = 16;
    // How far past each end the threshold travels, in field units, so a border or a
    // soft edge has fully left the screen at both ends of the fader.
    constant float kAVE5EdgeReach = 0.05;
    // Half the border band's width, in field units. Inside the reach above, so the
    // band is off-screen at both ends too.
    constant float kAVE5BorderHalfWidth = 0.025;
    // The circle's zigzag edge (manual p.3, note 7: "the edge of the hard and border
    // wipe in the circle wipe mode will be a zigzag"). The hardware's circle is
    // computed on a coarse horizontal clock; 90 steps across the line — 8 output
    // pixels at 720 across — matches the stair-step drawn in the manual. A count
    // across the line rather than a pixel size, because the hardware's clock is
    // tied to the line, not to whatever resolution this renders at.
    constant float kAVE5ZigzagColumns = 90.0;
    // Where a field can peak: the tile's four corners, its four edge midpoints, and
    // its centre (the textured diamond row peaks there).
    constant float2 kAVE5ReachProbes[9] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.5, 0.0), float2(0.5, 1.0), float2(0.0, 0.5), float2(1.0, 0.5),
        float2(0.5, 0.5)
    };
    // Width, in output pixels, of the column pairs the vertical textured pattern
    // alternates on — the same reason as kInterlaceBandPixels: single columns turn
    // to chroma mush through the composite codec.
    constant float kAVE5TextureColumnPixels = 4.0;

    /// One axis's ramp: 0 where B arrives first, 1 where it arrives last, or -1
    /// when neither of that axis's keys is lit.
    static inline float ave5Axis(bool fromHighSide, bool fromLowSide, float q, float centre) {
        if (fromHighSide && fromLowSide) { return 2.0 * abs(q - centre); }
        if (fromHighSide) { return 1.0 - q; }
        if (fromLowSide) { return q; }
        return -1.0;
    }

    /// The field before normalising. `q` is the position in the tile (0...1, y
    /// down), `c` the joystick centre in the same space.
    static inline float ave5RawField(int keys, float2 q, float2 c, float aspect, float2 pixel) {
        bool circle = (keys & kAVE5Circle) != 0;
        float ax = ave5Axis((keys & kAVE5FromRight) != 0, (keys & kAVE5FromLeft) != 0, q.x, c.x);
        float ay = ave5Axis((keys & kAVE5FromBottom) != 0, (keys & kAVE5FromTop) != 0, q.y, c.y);
        bool hasX = ax >= 0.0;
        bool hasY = ay >= 0.0;
        if (!circle) {
            if (hasX && hasY) { return max(ax, ay); }
            return hasX ? ax : ay;
        }
        if (!hasX && !hasY) { return length((q - c) * float2(aspect, 1.0)); }
        if (hasX && hasY) { return ax + ay; }
        // One axis plus the circle. The unlit axis still reaches the adder as a fold
        // at half strength: that is the difference the table draws between the
        // chevron (A|B + circle) and the triangle (A|B + A/B + B/A + circle).
        bool xFolded = (keys & (kAVE5FromRight | kAVE5FromLeft)) == (kAVE5FromRight | kAVE5FromLeft);
        bool yFolded = (keys & (kAVE5FromBottom | kAVE5FromTop)) == (kAVE5FromBottom | kAVE5FromTop);
        if (hasX) {
            float other = 2.0 * abs(q.y - 0.5);
            if (!xFolded) { return ax + 0.5 * other; }
            // Textured (A|B + B|A + circle). The table draws A as a dark bowtie with
            // B arriving top and bottom, hatched with horizontal lines — under MULTI
            // those meet across the tile edges as lemons pointed left and right.
            // Even lines: the hourglass; odd lines: plain bands from the top and
            // bottom edges. Where the two disagree is the hatching. An
            // approximation: the manual photographs these, it does not explain them.
            bool odd = (int(floor(pixel.y)) & 1) == 1;
            return odd ? (1.0 - other) : ax + (1.0 - other);
        }
        float other = 2.0 * abs(q.x - 0.5);
        if (!yFolded) { return ay + 0.5 * other; }
        // Textured (A/B + B/A + circle). The table draws A shrinking to a dark
        // diamond while B comes in from the corners, hatched with vertical lines.
        // Even columns: B from the corners; odd: B from the left and right edges.
        bool oddColumn = (int(floor(pixel.x / kAVE5TextureColumnPixels)) & 1) == 1;
        return oddColumn ? (1.0 - other) : (2.0 - ay - other);
    }

    struct AVE5Sample {
        float alpha;   // how much of B is here, 0...1
        float border;  // how much of the border colour is laid over it, 0...1
    };

    static inline AVE5Sample ave5Mask(constant BlendParams &p, float t, float2 uv,
                                      float2 pixel, float2 size) {
        AVE5Sample s;
        s.alpha = 0.0;
        s.border = 0.0;
        int keys = p.ave5Keys & 31;
        bool reversed = p.ave5Reversed != 0;
        // REVERSE: B arrives where A would have stayed — the forward pattern at the
        // mirrored fader position, inverted. Both ends are still the pure sources.
        float tt = reversed ? 1.0 - t : t;

        if (keys == 0) {
            // No pattern key lit is the manual's CUT (p.13, 8-1): the picture
            // switches at the middle of the lever's travel.
            s.alpha = tt >= 0.5 ? 1.0 : 0.0;
        } else {
            float aspect = size.x / max(size.y, 1.0);
            float2 at = uv;
            if (keys == kAVE5Circle && p.ave5Edge != 2) {
                at.x = (floor(uv.x * kAVE5ZigzagColumns) + 0.5) / kAVE5ZigzagColumns;
            }
            float tiles = float(max(p.ave5Tiles, 1));
            float2 scaled = at * tiles;
            float2 cell = floor(scaled);
            float2 q = scaled - cell;
            // Under MULTI the table draws the four diagonals mirrored top-to-bottom
            // on alternate rows of tiles — a zigzag rather than a repeat.
            int xKeys = keys & (kAVE5FromRight | kAVE5FromLeft);
            int yKeys = keys & (kAVE5FromBottom | kAVE5FromTop);
            bool diagonal = (keys & kAVE5Circle) != 0
                && (xKeys == kAVE5FromRight || xKeys == kAVE5FromLeft)
                && (yKeys == kAVE5FromBottom || yKeys == kAVE5FromTop);
            if (diagonal && (int(cell.y) & 1) == 1) { q.y = 1.0 - q.y; }

            float2 c = float2(p.ave5CentreX, p.ave5CentreY);
            float field = ave5RawField(keys, q, c, aspect, pixel);
            float reach = 1e-4;
            for (int i = 0; i < 9; i++) {
                reach = max(reach, ave5RawField(keys, kAVE5ReachProbes[i], c, aspect, pixel));
            }
            field /= reach;

            float threshold = tt * (1.0 + 2.0 * kAVE5EdgeReach) - kAVE5EdgeReach;
            if (p.ave5Edge == 2) {
                s.alpha = 1.0 - smoothstep(threshold - kAVE5EdgeReach,
                                           threshold + kAVE5EdgeReach, field);
            } else {
                s.alpha = field < threshold ? 1.0 : 0.0;
                if (p.ave5Edge == 1 && abs(field - threshold) < kAVE5BorderHalfWidth) {
                    s.border = 1.0;
                }
            }
        }
        if (reversed) { s.alpha = 1.0 - s.alpha; }
        return s;
    }

    fragment float4 composite_blend_fragment(VertexOut in [[stage_in]],
                                             texture2d<float> baseLayer [[texture(0)]],
                                             texture2d<float> blendLayer [[texture(1)]],
                                             constant BlendParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float t = clamp(p.mixAmount, 0.0, 1.0);

        // Anything but a dissolve: the pattern decides per pixel whether the right
        // source has arrived, and the blend mode colours what has arrived by the
        // same mid-travel triangle the dissolve uses below — so Normal is a clean
        // wipe and both fader ends are still the two sources untouched.
        // The AVE-5 wipe block. Its own branch rather than a case of transitionMask:
        // it has border and soft edges, so "arrived" is an amount, not a yes/no.
        if (p.transition == 12) {
            float2 size = float2(baseLayer.get_width(), baseLayer.get_height());
            AVE5Sample s = ave5Mask(p, t, in.uv, in.position.xy, size);
            float3 base = baseLayer.sample(linearSampler, in.uv).rgb;
            if (s.alpha <= 0.0 && s.border <= 0.0) { return float4(base, 1.0); }
            float3 blend = blendLayer.sample(linearSampler, in.uv).rgb;
            float3 raw = (p.mode == 13)
                ? keyComposite(base, blend, float3(p.keyR, p.keyG, p.keyB), p.keyThreshold, p.keyEdge)
                : blendChannelwise(p.mode, base, blend);
            float weight = 1.0 - abs(2.0 * t - 1.0);
            float3 arrived = mix(blend, clamp(raw, 0.0, 1.0), weight);
            float3 result = mix(base, arrived, s.alpha);
            result = mix(result, float3(p.ave5BorderR, p.ave5BorderG, p.ave5BorderB), s.border);
            return float4(clamp(result, 0.0, 1.0), 1.0);
        }

        if (p.transition != 0) {
            float aspect = float(baseLayer.get_width()) / max(float(baseLayer.get_height()), 1.0);
            TransitionSample s = transitionMask(p.transition, t, in.uv, in.position.xy, aspect);
            float3 base = baseLayer.sample(linearSampler, s.baseUV).rgb;
            if (s.inside < 0.5) { return float4(base, 1.0); }
            float3 blend = blendLayer.sample(linearSampler, s.blendUV).rgb;
            float3 raw = (p.mode == 13)
                ? keyComposite(base, blend, float3(p.keyR, p.keyG, p.keyB), p.keyThreshold, p.keyEdge)
                : blendChannelwise(p.mode, base, blend);
            float weight = 1.0 - abs(2.0 * t - 1.0);
            float3 arrived = mix(blend, clamp(raw, 0.0, 1.0), weight);
            return float4(clamp(arrived, 0.0, 1.0), 1.0);
        }

        float3 base = baseLayer.sample(linearSampler, in.uv).rgb;
        float3 blend = blendLayer.sample(linearSampler, in.uv).rgb;

        // Key (mode 13) is not a colour-combine function like the other twelve — it
        // selects between the two layers per pixel — so it bypasses blendChannelwise
        // entirely rather than being squeezed into its (mode, base, blend) shape.
        float3 rawBlended = (p.mode == 13)
            ? keyComposite(base, blend, float3(p.keyR, p.keyG, p.keyB), p.keyThreshold, p.keyEdge)
            : blendChannelwise(p.mode, base, blend);
        float3 blended = clamp(rawBlended, 0.0, 1.0);

        // The fader IS the opacity. Two things have to be true at once:
        //
        //   1. Hard left is the left source untouched, hard right the right source
        //      untouched — whatever the mode. That is what a crossfader means, and a
        //      blend mode must not take it away.
        //   2. Normal mode must still be an ordinary linear crossfade.
        //
        // So the blend is applied to the RIGHT-HAND SIDE of the mix, by an amount
        // that peaks in the middle and falls to nothing at both ends:
        //
        //      blendWeight = 1 - |2t - 1|          (a triangle peaking at t = 0.5)
        //      rightSide   = mix(blend, blended, blendWeight)
        //      result      = mix(base, rightSide, t)
        //
        // Mixing straight from base to `blended` instead would break (2): under
        // Normal, `blended` IS the blend layer, so the whole right half of the
        // fader's travel would do nothing at all.
        float blendWeight = 1.0 - abs(2.0 * t - 1.0);
        float3 rightSide = mix(blend, blended, blendWeight);
        float3 result = mix(base, rightSide, t);
        return float4(clamp(result, 0.0, 1.0), 1.0);
    }

    /* The datamosh as a layer over its own clean input (DatamoshNode, MoshHeal.swift).
     *
     * Two things in one pass, because both run every frame the card is doing more
     * than a plain mosh:
     *
     *   1. HEAL. `heal` (0...1) is how far the clean picture has come back. The shape
     *      decides which pixels come back first. Shape numbers match MoshHealShape.
     *        0 fade    — every pixel together
     *        1 blocks  — 16x16 macroblocks at random, as intra refresh looks
     *        2 wipe    — macroblock rows from the top down, as a refresh sweep looks
     *        3 luma    — the brightest parts of the clean picture first
     *   2. BLEND. The healed mosh is combined with the clean picture by a blend mode
     *      (`blendChannelwise`, same numbers as BlendMode) and laid over it at
     *      `opacity`. Normal at 1 is the mosh alone; anything at 0 is the clean input.
     */
    struct MoshLayerParams {
        float opacity;
        int mode;
        float heal;
        int shape;
        float blockSize;
        float seed;
    };

    fragment float4 mosh_layer_fragment(VertexOut in [[stage_in]],
                                        texture2d<float> cleanLayer [[texture(0)]],
                                        texture2d<float> moshLayer [[texture(1)]],
                                        constant MoshLayerParams &p [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float3 clean = cleanLayer.sample(linearSampler, in.uv).rgb;
        float3 mosh = moshLayer.sample(linearSampler, in.uv).rgb;

        float heal = clamp(p.heal, 0.0, 1.0);
        float back = 0.0;
        if (heal >= 1.0) {
            back = 1.0;
        } else if (heal > 0.0) {
            float2 block = floor(in.position.xy / max(p.blockSize, 1.0));
            float rows = ceil(float(cleanLayer.get_height()) / max(p.blockSize, 1.0));
            switch (p.shape) {
                case 1: {
                    float h = fract(sin(dot(block, float2(12.9898, 78.233)) + p.seed * 17.17) * 43758.5453);
                    back = step(h, heal);
                    break;
                }
                case 2:
                    back = step((block.y + 1.0) / max(rows, 1.0), heal);
                    break;
                case 3: {
                    float luma = dot(clean, float3(0.299, 0.587, 0.114));
                    back = smoothstep(1.0 - heal * 1.1, 1.1 - heal * 1.1, luma);
                    break;
                }
                default:
                    back = heal;
                    break;
            }
        }
        float3 healed = mix(mosh, clean, back);
        float3 blended = clamp(blendChannelwise(p.mode, clean, healed), 0.0, 1.0);
        float3 result = mix(clean, blended, clamp(p.opacity, 0.0, 1.0));
        return float4(clamp(result, 0.0, 1.0), 1.0);
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
    /// Layer compositing with a blend mode and per-layer opacity.
    public let blendPipeline: MTLRenderPipelineState
    /// A scope screened over the picture, in a chosen rectangle.
    public let scopeOverlayPipeline: MTLRenderPipelineState
    /// Synthetic generators: solids, gradients, patterns and noise fields.
    public let generatorPipeline: MTLRenderPipelineState
    /// Echo/trails: blends a frame with the decaying history behind it.
    public let echoPipeline: MTLRenderPipelineState
    public let colourPipeline: MTLRenderPipelineState
    public let transformPipeline: MTLRenderPipelineState
    /// Feedback: the previous output, transformed, mixed back in.
    public let feedbackPipeline: MTLRenderPipelineState
    /// The datamosh laid over its clean input: heal shape, blend mode, opacity.
    public let moshLayerPipeline: MTLRenderPipelineState
    /// Places a source picture inside the canvas (`CanvasFit`).
    public let fitPipeline: MTLRenderPipelineState

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
              let blend = makePipeline(vertex: "fullscreen_vertex", fragment: "composite_blend_fragment"),
              let scopeOverlay = makePipeline(
                vertex: "fullscreen_vertex", fragment: "scope_overlay_fragment"),
              let generator = makePipeline(vertex: "fullscreen_vertex", fragment: "generator_fragment"),
              let echo = makePipeline(vertex: "fullscreen_vertex", fragment: "echo_fragment"),
              let colour = makePipeline(vertex: "fullscreen_vertex", fragment: "colour_fragment"),
              let transform = makePipeline(vertex: "fullscreen_vertex", fragment: "transform_fragment"),
              let feedback = makePipeline(vertex: "fullscreen_vertex", fragment: "feedback_fragment"),
              let moshLayer = makePipeline(vertex: "fullscreen_vertex", fragment: "mosh_layer_fragment"),
              let fit = makePipeline(vertex: "fullscreen_vertex", fragment: "fit_fragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.blitPipeline = blit
        self.crossfadePipeline = crossfade
        self.compositePipeline = composite
        self.blendPipeline = blend
        self.scopeOverlayPipeline = scopeOverlay
        self.generatorPipeline = generator
        self.echoPipeline = echo
        self.colourPipeline = colour
        self.transformPipeline = transform
        self.feedbackPipeline = feedback
        self.moshLayerPipeline = moshLayer
        self.fitPipeline = fit
        Log.info(.render, "Metal ready on \(device.name)")
    }

    // MARK: - Submitting passes
    //
    // WHY PASSES NO LONGER WAIT. Every node used to `commit()` then
    // `waitUntilCompleted()` — a full CPU↔GPU round trip, ~0.3–0.6 ms each, for
    // shader work that takes microseconds on a 720×480 frame. With four channels and
    // every effect on that was ~11 ms of a 19 ms frame spent waiting, and the app fell
    // to half the display rate (measured by `selfqa.sh stress`).
    //
    // All passes share ONE command queue, and Metal runs a queue's command buffers in
    // commit order with hazard tracking, so a later pass always sees an earlier pass's
    // writes without the CPU stopping in between. The engine then waits ONCE per frame
    // (`waitForIdle`), which keeps the invariant everything else relies on: when the
    // graph returns, every texture it produced is finished. CPU readers mid-graph
    // (`OffscreenRenderer.readback`) wait on their own buffer, which on one queue
    // implies everything before it is done.

    /// Restores the old wait-after-every-pass behaviour. An instant fallback if a
    /// picture ever looks wrong: launch with `VIDEOBOY_SYNC_EVERY_PASS=1`.
    public nonisolated(unsafe) static var syncsEveryPass =
        ProcessInfo.processInfo.environment["VIDEOBOY_SYNC_EVERY_PASS"] == "1"

    /// Commits a pass. Returns immediately unless `syncsEveryPass` is set; a GPU
    /// failure is still logged, from the completion handler instead of inline.
    public func submit(_ commandBuffer: MTLCommandBuffer, label: String) {
        if Self.syncsEveryPass {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                Log.error(.render, "\(label) GPU pass failed: \(error)")
            }
            return
        }
        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                Log.error(.render, "\(label) GPU pass failed: \(error)")
            }
        }
        commandBuffer.commit()
    }

    /// Blocks until every pass submitted so far has finished. Called once per frame.
    public func waitForIdle() {
        guard let buffer = commandQueue.makeCommandBuffer() else { return }
        buffer.label = "frame-fence"
        buffer.commit()
        buffer.waitUntilCompleted()
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

        // CLEARED BEFORE IT IS HANDED OVER. A fresh Metal texture contains whatever
        // was in that memory, and any effect that keeps FRAME HISTORY — the echo's
        // two buffers, the feedback ring — reads its own target before it has ever
        // written to it. With a high decay that garbage does not fade out; it sits
        // under the picture as a coloured wash for as long as the effect is on,
        // which is what "echo trails doesn't work" turned out to be: the trail was
        // there all along, behind a purple screen.
        //
        // Clearing every render target rather than only the history ones, because
        // the alternative is a rule each future caller has to remember, and the cost
        // is one pass at allocation — on resize, not per frame.
        clearToBlack(texture)
        return texture
    }

    /// Fills a texture with opaque black.
    private func clearToBlack(_ texture: MTLTexture) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.warn(.render, "could not clear '\(texture.label ?? "target")'; it may show garbage")
            return
        }
        encoder.endEncoding()
        submit(buffer, label: "clear '\(texture.label ?? "target")'")
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
        submit(commandBuffer, label: "\(label) wet/dry blend")
        return true
    }

    /// Tiles up to four textures into one, for a multi-view send to a monitor.
    ///
    /// A performer watching four sources on one screen wants them side by side, not
    /// four windows to arrange. Missing inputs leave their quadrant black rather than
    /// shifting the others around — the position of a quadrant is how you know which
    /// source it is, so it has to stay put whether or not anything is loaded.
    ///
    /// - Parameter textures: up to four, in reading order: top-left, top-right,
    ///   bottom-left, bottom-right.
    /// - Returns: false if the pass could not be encoded.
    public func tile(
        _ textures: [MTLTexture?], into target: MTLTexture, label: String
    ) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(label) could not encode its tiled view")
            return false
        }
        encoder.label = "\(label)-tile"
        encoder.setRenderPipelineState(blitPipeline)

        let halfWidth = Double(target.width) / 2
        let halfHeight = Double(target.height) / 2
        // Reading order, with the origin at the top left as viewports are measured.
        let quadrants: [(x: Double, y: Double)] = [
            (0, 0), (halfWidth, 0), (0, halfHeight), (halfWidth, halfHeight)
        ]

        for (index, quadrant) in quadrants.enumerated() {
            guard index < textures.count, let texture = textures[index] else { continue }
            encoder.setViewport(MTLViewport(
                originX: quadrant.x, originY: quadrant.y,
                width: halfWidth, height: halfHeight,
                znear: 0, zfar: 1
            ))
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        submit(commandBuffer, label: "\(label) tiled view")
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
