//
//  ISFBuiltinParityTests.swift — the ISF built-ins against the native nodes they replace.
//
//  The gate from docs/ISF-PLAN.md §4.2: before a native effect is retired, its ISF port
//  must produce the same picture (mean ≤ 0.5/255, max ≤ 2/255 per channel), from the
//  SAME registry values under the SAME param codes — which is also what proves saved
//  templates and MIDI mappings keep working after the swap — and must not cost
//  meaningfully more.
//
//  Evidence: selfqa/out/isf/parity/ (source, native and ISF PNGs, result.txt).
//

import XCTest
import Metal
@testable import VideoboyCore

final class ISFBuiltinParityTests: XCTestCase {

    private var metal: MetalContext!
    private var renderer: OffscreenRenderer!

    /// The plan's tolerances, in 0...255 units.
    private let meanTolerance = 0.5
    private let maxTolerance = 2

    override func setUpWithError() throws {
        Log.echoesToStandardError = false
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        self.metal = metal
        self.renderer = renderer
    }

    private func builtin(_ name: String) throws -> ISFNode {
        let url = ISFLibrary.builtinFolder.appendingPathComponent("\(name).fs")
        let source = try String(contentsOf: url, encoding: .utf8)
        return try ISFTestSupport.node(source, name: name, metal: metal)
    }

    /// Sets the same natural-unit values on both nodes through one registry each, the
    /// way the engine does.
    private func apply(_ values: [ParamCode: Double], native: Node & RegistryDriven, isf: ISFNode) {
        for (node, apply) in [(native as Node, native.applyParameters(from:)),
                              (isf as Node, isf.applyParameters(from:))] {
            let registry = ParamRegistry()
            registry.register(slot: node.identifier, parameters: node.parameters)
            for (code, value) in values {
                XCTAssertTrue(registry.setValue(value, slot: node.identifier, code: code),
                              "\(node.identifier) does not expose \(code.rawValue)")
            }
            apply(registry)
        }
    }

    private func read(_ texture: MTLTexture?) throws -> ImageBuffer {
        guard let texture, let image = renderer.readback(texture) else { throw XCTSkip("readback failed") }
        return image
    }

    /// Renders both, compares, records the result and writes evidence.
    private func compare(
        _ label: String, native: Node, isf: ISFNode, input: MTLTexture, frame: Int,
        check: SelfQACheck, writeImages: Bool
    ) throws {
        let context = ISFTestSupport.context(frame: frame)
        let nativeImage = try read(native.render(inputs: [input], context: context))
        let isfImage = try read(isf.render(inputs: [input], context: context))
        let diff = ISFTestSupport.difference(nativeImage, isfImage)
        let passed = diff.mean <= meanTolerance && diff.max <= maxTolerance
        check.record(AssertionResult(
            name: "\(label) matches native",
            passed: passed,
            detail: String(format: "mean %.3f, max %d (limits %.1f / %d)", diff.mean, diff.max, meanTolerance, maxTolerance)))
        XCTAssertTrue(passed, "\(label): mean \(diff.mean), max \(diff.max)")
        if writeImages {
            let slug = label.lowercased().replacingOccurrences(of: " ", with: "-")
            try check.writeImage(nativeImage, named: "\(slug)-native.png")
            try check.writeImage(isfImage, named: "\(slug)-isf.png")
        }
    }

    // MARK: - The gate

    func testBuiltinsMatchTheNativeEffectsTheyReplace() throws {
        let check = SelfQACheck(name: "isf/parity")
        let source = ISFTestSupport.gradient(width: 360, height: 240)
        guard let input = metal.makeTexture(from: source, label: "parity-in") else { throw XCTSkip("upload") }
        try check.writeImage(source, named: "00-source.png")
        check.note("fixture: 360x240 gradient (red→right, green→down, blue checker) — every pixel distinct, orientation obvious")

        // Colour: five grades, then a half-wet one through the shared blend.
        let colourCases: [(String, [ParamCode: Double])] = [
            ("colour 1 contrast", [.contrast: 1.4]),
            ("colour 2 bright-desat", [.brightness: 0.2, .saturation: 0.3]),
            ("colour 3 shadow-highlight", [.shadow: 0.5, .highlight: -0.4]),
            ("colour 4 levels-gamma", [.blackLevel: 0.1, .whiteLevel: 0.8, .gamma: 1.8]),
            ("colour 5 everything", [.contrast: 0.7, .brightness: -0.1, .saturation: 1.6, .shadow: -0.3,
                                     .highlight: 0.2, .blackLevel: 0.05, .whiteLevel: 0.95, .gamma: 0.6]),
            ("colour 6 half wet", [.contrast: 1.8, .saturation: 0.0, .wetDry: 0.5])
        ]
        for (index, (label, values)) in colourCases.enumerated() {
            let native = ColourControlNode(identifier: "parity.colour.native", context: metal)
            let isf = try builtin("Colour")
            apply(values, native: native, isf: isf)
            try compare(label, native: native, isf: isf, input: input, frame: 0, check: check, writeImages: index < 2)
        }

        // Transform: every control, alone and combined, including flips and offsets —
        // the ones whose signs change between Metal's y-down and ISF's y-up.
        let transformCases: [(String, [ParamCode: Double])] = [
            ("transform 1 scale", [.scale: 1.5]),
            ("transform 2 rotate", [.rotation: 0.125]),
            ("transform 3 flipH posX", [.flipHorizontal: 1, .positionX: 0.2]),
            ("transform 4 flipV posY shrink", [.flipVertical: 1, .positionY: -0.3, .scale: 0.7]),
            ("transform 5 everything", [.rotation: 0.3, .scale: 2.0, .positionX: -0.1, .positionY: 0.15,
                                        .flipHorizontal: 1])
        ]
        for (index, (label, values)) in transformCases.enumerated() {
            let native = TransformNode(identifier: "parity.transform.native", context: metal)
            let isf = try builtin("Transform")
            apply(values, native: native, isf: isf)
            try compare(label, native: native, isf: isf, input: input, frame: 0, check: check,
                        writeImages: index == 1 || index == 4)
        }

        // Echo: stateful, so compare a whole moving sequence frame by frame. A bright
        // square walks across a dark field; the trail is the history.
        let echoCases: [(String, [ParamCode: Double])] = [
            ("echo defaults", [:]),
            ("echo long trail", [.echoDecay: 0.95, .trailLength: 0.9, .echoThreshold: 0.3])
        ]
        for (label, values) in echoCases {
            let native = EchoNode(identifier: "parity.echo.native", context: metal)
            let isf = try builtin("Echo")
            apply(values, native: native, isf: isf)
            for frame in 0..<8 {
                var image = TestPattern.solid(width: 160, height: 120, r: 10, g: 10, b: 30)
                for y in 40..<80 { for x in (10 + frame * 16)..<(40 + frame * 16) {
                    image.setPixel(x: x, y: y, r: 250, g: 200, b: 60)
                } }
                guard let frameTexture = metal.makeTexture(from: image, label: "echo-frame") else { throw XCTSkip("upload") }
                try compare("\(label) frame \(frame)", native: native, isf: isf, input: frameTexture,
                            frame: frame, check: check, writeImages: frame == 7)
            }
        }

        try recordCost(check: check)
        let verdict = check.finish()
        XCTAssertEqual(verdict, .pass)
    }

    // MARK: - Cost

    /// Times native and ISF over many frames, each fenced, at the real SD size, and
    /// records both. Best of three interleaved rounds, so a background hiccup cannot
    /// land on one side only. The gate is deliberately loose here (ISF ≤ 1.5× native
    /// + 0.1 ms) because wall-clock timing of sub-millisecond passes in a test runner is
    /// noisy; the numbers go into result.txt so the plan's stricter +10% reading can be
    /// made by eye, and the live check of record remains `scripts/selfqa.sh stress`.
    private func recordCost(check: SelfQACheck) throws {
        let frames = 200
        let source = ISFTestSupport.gradient(width: StandardDefinition.width, height: StandardDefinition.height)
        guard let input = metal.makeTexture(from: source, label: "cost-in") else { throw XCTSkip("upload") }
        let context = ISFTestSupport.context()

        func time(_ node: Node) -> Double {
            for _ in 0..<20 { _ = node.render(inputs: [input], context: context); metal.waitForIdleForTests() }
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<frames {
                _ = node.render(inputs: [input], context: context)
                metal.waitForIdleForTests()
            }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames)
        }

        let pairs: [(String, Node & RegistryDriven, ISFNode, [ParamCode: Double])] = [
            ("Colour", ColourControlNode(identifier: "cost.colour", context: metal), try builtin("Colour"),
             [.contrast: 1.3, .gamma: 1.4]),
            ("Transform", TransformNode(identifier: "cost.transform", context: metal), try builtin("Transform"),
             [.rotation: 0.2, .scale: 1.3]),
            ("Echo", EchoNode(identifier: "cost.echo", context: metal), try builtin("Echo"), [:])
        ]
        for (name, native, isf, values) in pairs {
            apply(values, native: native, isf: isf)
            var nativeMs = Double.infinity
            var isfMs = Double.infinity
            for _ in 0..<3 {
                nativeMs = min(nativeMs, time(native))
                isfMs = min(isfMs, time(isf))
            }
            let passed = isfMs <= nativeMs * 1.5 + 0.1
            check.record(AssertionResult(
                name: "\(name) ISF costs no more than native",
                passed: passed,
                detail: String(format: "native %.3f ms, ISF %.3f ms per fenced frame (%+.0f%%) at 720x480, best of 3",
                               nativeMs, isfMs, (isfMs / max(nativeMs, 0.0001) - 1) * 100)))
            XCTAssertTrue(passed, "\(name): native \(nativeMs) ms, ISF \(isfMs) ms")
        }
    }
}

/// The native effects' shared shape: they pull their settings from a registry.
protocol RegistryDriven: AnyObject {
    func applyParameters(from registry: ParamRegistry)
}
extension ColourControlNode: RegistryDriven {}
extension TransformNode: RegistryDriven {}
extension EchoNode: RegistryDriven {}

extension MetalContext {
    /// Waits for every pass submitted so far. Tests only — a fence buffer on the one
    /// queue, so this works whether or not a node waited for itself.
    func waitForIdleForTests() {
        guard let buffer = commandQueue.makeCommandBuffer() else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
