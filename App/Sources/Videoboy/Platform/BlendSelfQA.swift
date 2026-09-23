//
//  BlendSelfQA.swift — a contact sheet of every blend mode, from the live graph.
//
//  Purpose : The blend arithmetic is unit-tested against hand-computed values; this
//            renders each mode over real pictures through the engine's own mixer so
//            the results can actually be looked at, and so a mode that is correct on
//            flat colours but wrong on real content would be visible.
//  Inputs  : samples/*.dv.
//  Outputs : selfqa/out/phase-4/blend-modes/{*.png,result.txt}.
//  Connects: Engine, CrossfadeNode, BlendMode.
//

import AppKit
import Metal
import VideoboyCore

/// Renders every blend mode over the same pair of layers.
enum BlendSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/blend-modes")

        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available")
        }

        let samples = RepoPaths.samples
        let fileA = samples.appendingPathComponent("motion.dv")
        let fileB = samples.appendingPathComponent("bars.dv")
        for file in [fileA, fileB] where !FileManager.default.fileExists(atPath: file.path) {
            return check.finish(blockedReason: "\(file.lastPathComponent) is missing — run scripts/make-fixtures.sh")
        }

        let engine = Engine()
        guard engine.load(url: fileA, intoChannel: "A"), engine.load(url: fileB, intoChannel: "B") else {
            check.record(AssertionResult(name: "sources load", passed: false, detail: "a DV file failed to load"))
            return check.finish()
        }
        // Bus effects off: this check is about the compositor.
        for slot in Engine.busEffectSlots {
            engine.registry.setValue(0, slot: slot, code: .wetDry)
        }
        // The MIDPOINT, not fully across. `composite_blend_fragment`'s own contract
        // (MetalContext.swift) is that hard left is the base untouched and hard
        // right is the blend layer untouched, WHATEVER THE MODE — a blend mode only
        // has any effect at all in between, peaking exactly at 0.5. This check used
        // to sit at 1.0, where every mode collapses to the same pure-B frame and
        // "modes are distinct from normal" cannot ever pass — found while adding
        // the Key mode and confirming it actually did something here.
        engine.registry.setValue(0.5, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(1.0, slot: GraphTopology.subMixOne, code: .layerOpacity)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        check.note("A = motion.dv (base), B = bars.dv (blend layer), through the engine's ONE bus")

        func render(_ frameIndex: Int) -> ImageBuffer? {
            let context = RenderContext(
                frameIndex: frameIndex,
                presentationTime: Double(frameIndex) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            guard let texture = engine.evaluateGraph(context: context)[GraphTopology.subMixOne] else {
                return nil
            }
            return renderer.readback(texture)
        }

        var results: [BlendMode: ImageBuffer] = [:]
        for (index, mode) in BlendMode.allCases.enumerated() {
            engine.registry.setValue(
                mode.normalisedPosition, slot: GraphTopology.subMixOne, code: .blendMode)
            guard let image = render(index) else {
                check.record(AssertionResult(
                    name: "\(mode.displayName) renders", passed: false, detail: "no texture"))
                continue
            }
            results[mode] = image
            _ = try? check.writeImage(
                image, named: String(format: "%02d-%@.png", index, mode.displayName
                    .lowercased().replacingOccurrences(of: " ", with: "-")))
            check.record(FrameAssertions.hasDimensions(image, width: 720, height: 480))
        }

        check.record(AssertionResult(
            name: "every blend mode rendered",
            passed: results.count == BlendMode.allCases.count,
            detail: "\(results.count) of \(BlendMode.allCases.count)"
        ))

        // The modes must actually differ from each other. Two modes producing an
        // identical frame would mean one of them is not wired to the shader.
        if let normal = results[.normal] {
            var distinct = 0
            for mode in BlendMode.allCases where mode != .normal {
                guard let image = results[mode] else { continue }
                if FrameAssertions.differingPixelFraction(normal, image) > 0.01 { distinct += 1 }
            }
            check.record(AssertionResult(
                name: "modes are distinct from normal",
                passed: distinct >= BlendMode.allCases.count - 2,
                detail: "\(distinct) of \(BlendMode.allCases.count - 1) differ from Normal"
            ))
        }

        // Multiply must be darker than the base and screen brighter — the two
        // sanity checks that catch a swapped or mis-indexed mode table.
        if let multiply = results[.multiply], let screen = results[.screen], let normal = results[.normal] {
            let multiplyLuma = luma(FrameAssertions.meanColor(multiply))
            let screenLuma = luma(FrameAssertions.meanColor(screen))
            let normalLuma = luma(FrameAssertions.meanColor(normal))
            check.record(AssertionResult(
                name: "multiply darkens and screen lightens",
                passed: multiplyLuma < normalLuma && screenLuma > normalLuma,
                detail: "multiply \(String(format: "%.0f", multiplyLuma)), normal \(String(format: "%.0f", normalLuma)), screen \(String(format: "%.0f", screenLuma))"
            ))
        }

        return check.finish()
    }

    /// Rec.601 luma of a mean colour.
    private static func luma(_ color: (r: Double, g: Double, b: Double)) -> Double {
        0.299 * color.r + 0.587 * color.g + 0.114 * color.b
    }
}
