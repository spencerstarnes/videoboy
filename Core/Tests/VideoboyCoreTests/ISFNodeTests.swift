//
//  ISFNodeTests.swift — an ISF file running as a graph node, proved on pixels.
//
//  Each test renders on the GPU and reads the result back. What is pinned here is
//  what the rest of the app relies on: an identity shader changes nothing, "up" in a
//  shader is up on screen, a node that is not ready passes its input through, and a
//  bypassed node costs nothing and forgets nothing.
//

import XCTest
import Metal
@testable import VideoboyCore

/// Shared helpers for the ISF pixel tests.
enum ISFTestSupport {

    /// A picture where every pixel is different and orientation is obvious:
    /// red rises left→right, green rises top→bottom, blue is a checkerboard.
    static func gradient(width: Int = 96, height: Int = 64) -> ImageBuffer {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / (width - 1))
                pixels[i + 1] = UInt8(y * 255 / (height - 1))
                pixels[i + 2] = ((x / 8 + y / 8) % 2 == 0) ? 40 : 220
            }
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Mean and max absolute RGB difference, in 0...255 units.
    static func difference(_ a: ImageBuffer, _ b: ImageBuffer) -> (mean: Double, max: Int) {
        precondition(a.width == b.width && a.height == b.height)
        var total = 0
        var largest = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = a.pixel(x: x, y: y)
                let q = b.pixel(x: x, y: y)
                for d in [abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b))] {
                    total += d
                    largest = max(largest, d)
                }
            }
        }
        return (Double(total) / Double(a.width * a.height * 3), largest)
    }

    /// Builds a ready node from source, compiling synchronously (tests only).
    static func node(_ source: String, name: String = "test", metal: MetalContext) throws -> ISFNode {
        let program = try ISFProgram.compile(source: source, name: name, device: metal.device)
        let node = ISFNode(identifier: "test.isf.\(name)", context: metal)
        node.install(program)
        return node
    }

    static func context(frame: Int = 0, time: Double = 0) -> RenderContext {
        RenderContext(frameIndex: frame, presentationTime: time, musicalPosition: nil)
    }
}

final class ISFNodeTests: XCTestCase {

    private var metal: MetalContext!
    private var renderer: OffscreenRenderer!

    override func setUpWithError() throws {
        Log.echoesToStandardError = false
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        self.metal = metal
        self.renderer = renderer
    }

    private func upload(_ image: ImageBuffer) throws -> MTLTexture {
        guard let texture = metal.makeTexture(from: image, label: "isf-test-in") else {
            throw XCTSkip("could not upload")
        }
        return texture
    }

    private func effect(_ body: String, inputs: String = "", extra: String = "") -> String {
        let more = inputs.isEmpty ? "" : ",\n" + inputs
        return """
        /*{
            \(extra)
            "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" }\(more) ]
        }*/
        \(body)
        """
    }

    private func render(_ node: ISFNode, _ input: MTLTexture?, frame: Int = 0, time: Double = 0) throws -> ImageBuffer {
        let inputs = input.map { [$0] } ?? []
        guard let out = node.render(inputs: inputs, context: ISFTestSupport.context(frame: frame, time: time)),
              let read = renderer.readback(out) else {
            throw XCTSkip("render failed")
        }
        return read
    }

    // MARK: - Pictures

    func testAnIdentityShaderChangesNothing() throws {
        let image = ISFTestSupport.gradient()
        let node = try ISFTestSupport.node(
            effect("void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage); }"), metal: metal)
        let out = try render(node, try upload(image))
        let diff = ISFTestSupport.difference(out, image)
        XCTAssertEqual(diff.max, 0, "identity must be exact, got mean \(diff.mean) max \(diff.max)")
    }

    func testPixelAddressingIsAlsoExact() throws {
        let image = ISFTestSupport.gradient()
        let node = try ISFTestSupport.node(
            effect("void main() { gl_FragColor = IMG_PIXEL(inputImage, gl_FragCoord.xy); }"), metal: metal)
        let out = try render(node, try upload(image))
        XCTAssertEqual(ISFTestSupport.difference(out, image).max, 0)
    }

    func testUpInAShaderIsUpOnScreen() throws {
        // ISF coordinates are OpenGL's: y = 1 is the TOP of the picture. Texture row 0
        // is the top row. Getting this backwards flips every third-party effect.
        let node = try ISFTestSupport.node(effect("""
        void main() {
            gl_FragColor = vec4(isf_FragNormCoord.y, gl_FragCoord.y / RENDERSIZE.y, 0.0, 1.0);
        }
        """), metal: metal)
        let out = try render(node, try upload(ISFTestSupport.gradient()))
        let top = out.pixel(x: 10, y: 0)
        let bottom = out.pixel(x: 10, y: out.height - 1)
        XCTAssertGreaterThan(top.r, 245)
        XCTAssertLessThan(bottom.r, 10)
        XCTAssertGreaterThan(top.g, 245, "gl_FragCoord agrees with isf_FragNormCoord")
        XCTAssertLessThan(bottom.g, 10)
    }

    func testMovingUpInAShaderMovesThePictureUp() throws {
        // Sample from lower down → the picture moves up. Green rises toward the bottom
        // of the gradient, so the top row now shows a greener (lower) row.
        let image = ISFTestSupport.gradient()
        let node = try ISFTestSupport.node(effect("""
        void main() { gl_FragColor = IMG_NORM_PIXEL(inputImage, isf_FragNormCoord - vec2(0.0, 0.25)); }
        """), metal: metal)
        let out = try render(node, try upload(image))
        XCTAssertEqual(Int(out.pixel(x: 10, y: 0).g), Int(image.pixel(x: 10, y: 16).g), accuracy: 3)
    }

    // MARK: - Not ready, bypassed, neutral

    func testANodeWithNoProgramPassesItsInputThrough() throws {
        let input = try upload(ISFTestSupport.gradient())
        let node = ISFNode(identifier: "test.isf.empty", context: metal)
        XCTAssertEqual(node.state, .compiling)
        XCTAssertTrue(node.render(inputs: [input], context: ISFTestSupport.context()) === input)
        node.markFailed("line 3: nope")
        XCTAssertEqual(node.state, .failed("line 3: nope"))
        XCTAssertTrue(node.render(inputs: [input], context: ISFTestSupport.context()) === input)
    }

    func testLoadingCompilesOffTheMainThreadAndReportsFailures() throws {
        let good = ISFNode(identifier: "test.isf.async-good", context: metal)
        let bad = ISFNode(identifier: "test.isf.async-bad", context: metal)
        let compiler = ISFCompiler()
        good.load(source: effect("void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage); }"),
                  name: "good", compiler: compiler)
        bad.load(source: effect("void main() {\n  gl_FragColor = nonsense;\n}"), name: "bad", compiler: compiler)
        XCTAssertEqual(good.state, .compiling, "nothing is compiled synchronously")

        let deadline = Date().addingTimeInterval(10)
        while (good.state == .compiling || bad.state == .compiling) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(good.state, .ready)
        guard case .failed(let reason) = bad.state else { return XCTFail("expected failure, got \(bad.state)") }
        XCTAssertTrue(reason.hasPrefix("line 6:"), "reason was: \(reason)")
    }

    func testFullyDryIsFreeAndKeepsPersistentBuffers() throws {
        let node = try ISFTestSupport.node(effect("""
        void main() {
            if (PASSINDEX == 0) { gl_FragColor = IMG_THIS_PIXEL(acc) + vec4(0.1, 0.1, 0.1, 1.0); }
        }
        """, extra: #""PASSES": [ { "TARGET": "acc", "PERSISTENT": true } ],"#), metal: metal)
        let input = try upload(TestPattern.solid(width: 32, height: 32, r: 0, g: 0, b: 0))

        let first = try render(node, input)
        node.wetDry = 0
        XCTAssertTrue(node.render(inputs: [input], context: ISFTestSupport.context()) === input)
        node.wetDry = 1
        let second = try render(node, input)
        XCTAssertEqual(Int(first.pixel(x: 5, y: 5).r), 26, accuracy: 1)
        XCTAssertEqual(Int(second.pixel(x: 5, y: 5).r), 51, accuracy: 1,
                       "the bypassed frame neither advanced nor cleared the buffer")
    }

    func testIdentityAtDefaultsSkipsThePass() throws {
        let node = try ISFTestSupport.node(effect(
            "void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage) * gain; }",
            inputs: #"{ "NAME": "gain", "TYPE": "float", "DEFAULT": 1.0 }"#,
            extra: #""VIDEOBOY": { "IDENTITY_AT_DEFAULTS": true },"#), metal: metal)
        let input = try upload(ISFTestSupport.gradient())
        XCTAssertTrue(node.isAtDefaults)
        XCTAssertTrue(node.render(inputs: [input], context: ISFTestSupport.context()) === input)
        node.setValue(0.5, forInput: "gain")
        XCTAssertFalse(node.render(inputs: [input], context: ISFTestSupport.context()) === input)
    }

    // MARK: - Passes

    func testMultiPassWithASmallerBuffer() throws {
        let node = try ISFTestSupport.node(effect("""
        void main() {
            if (PASSINDEX == 0) {
                gl_FragColor = vec4(RENDERSIZE / 255.0, 0.0, 1.0);
            } else {
                gl_FragColor = IMG_THIS_PIXEL(small);
            }
        }
        """, extra: #""PASSES": [ { "TARGET": "small", "WIDTH": "$WIDTH/4", "HEIGHT": "$HEIGHT/4" }, {} ],"#),
                                               metal: metal)
        let out = try render(node, try upload(ISFTestSupport.gradient(width: 96, height: 64)))
        XCTAssertEqual(out.width, 96, "the output is full size")
        let pixel = out.pixel(x: 48, y: 32)
        XCTAssertEqual(Int(pixel.r), 24, accuracy: 1, "pass 0 saw RENDERSIZE.x = 96/4")
        XCTAssertEqual(Int(pixel.g), 16, accuracy: 1, "pass 0 saw RENDERSIZE.y = 64/4")
    }

    func testFloatBuffersKeepSmallIncrements() throws {
        // 1/1024 per frame is below one 8-bit step; a FLOAT buffer accumulates it.
        let node = try ISFTestSupport.node(effect("""
        void main() {
            if (PASSINDEX == 0) {
                gl_FragColor = IMG_THIS_PIXEL(acc) + vec4(1.0 / 1024.0);
            } else {
                gl_FragColor = vec4(IMG_THIS_PIXEL(acc).rgb * 8.0, 1.0);
            }
        }
        """, extra: #""PASSES": [ { "TARGET": "acc", "PERSISTENT": true, "FLOAT": true }, {} ],"#), metal: metal)
        let input = try upload(TestPattern.solid(width: 16, height: 16, r: 0, g: 0, b: 0))
        var last: ImageBuffer?
        for frame in 0..<64 { last = try render(node, input, frame: frame) }
        // 64/1024 * 8 = 0.5 → 127.
        XCTAssertEqual(Int(last?.pixel(x: 4, y: 4).r ?? 0), 127, accuracy: 3)
    }

    func testAGeneratorRendersAtTheProjectSize() throws {
        let node = try ISFTestSupport.node("""
        /*{ "INPUTS": [] }*/
        void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
        """, metal: metal)
        XCTAssertEqual(node.kind, .source)
        let out = try render(node, nil)
        XCTAssertEqual(out.width, StandardDefinition.width)
        XCTAssertEqual(out.height, StandardDefinition.height)
        XCTAssertGreaterThan(out.pixel(x: 100, y: 100).r, 250)
    }

    // MARK: - Time and parameters

    func testTimeFollowsThePresentationClock() throws {
        let node = try ISFTestSupport.node(effect(
            "void main() { gl_FragColor = vec4(fract(TIME), float(FRAMEINDEX) / 255.0, 0.0, 1.0); }"),
                                               metal: metal)
        let input = try upload(ISFTestSupport.gradient())
        _ = try render(node, input, frame: 0, time: 10.0)
        let later = try render(node, input, frame: 1, time: 10.25)
        XCTAssertEqual(Int(later.pixel(x: 5, y: 5).r), 64, accuracy: 1, "TIME counts from the node's first frame")
        XCTAssertEqual(Int(later.pixel(x: 5, y: 5).g), 1, "FRAMEINDEX counts renders")
    }

    func testDeclaredCodesReachTheRegistry() throws {
        let node = try ISFTestSupport.node(effect(
            "void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage) * amount; }",
            inputs: """
            { "NAME": "amount", "TYPE": "float", "MIN": 0.0, "MAX": 2.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "21A" },
            { "NAME": "local", "TYPE": "float" },
            { "NAME": "bogus", "TYPE": "float", "VIDEOBOY_CODE": "ZZZ" }
            """), metal: metal)
        let codes = node.parameters.map(\.code)
        // EVERY input is addressable (ISF-PLAN M2): a declared code where it is a real
        // one, `x:<name>` otherwise — including an input whose declared code is junk.
        XCTAssertEqual(codes, [.wetDry, .echoDecay, .isolated(inputName: "local"), .isolated(inputName: "bogus")])
        XCTAssertEqual(node.parameters[1].range, 0...2)

        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        registry.setValue(1.5, slot: node.identifier, code: .echoDecay)
        registry.setValue(0.3, slot: node.identifier, code: .isolated(inputName: "local"))
        registry.setValue(0.25, slot: node.identifier, code: .wetDry)
        node.applyParameters(from: registry)
        XCTAssertEqual(node.value(ofInput: "amount"), [1.5])
        XCTAssertEqual(node.value(ofInput: "local"), [0.3], "an undeclared input is reachable through its x: code")
        XCTAssertEqual(node.wetDry, 0.25)
    }

    func testControlsAreKnownBeforeTheProgramCompiles() throws {
        // A compiler that never answers: whatever the node knows, it knows from the header.
        let node = ISFNode(identifier: "test.early", context: metal)
        node.load(source: effect(
            "void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage) * glow; }",
            inputs: """
            { "NAME": "glow", "TYPE": "float", "DEFAULT": 0.5 },
            { "NAME": "tint", "TYPE": "color", "DEFAULT": [1.0, 0.5, 0.25, 1.0] },
            { "NAME": "centre", "TYPE": "point2D", "MIN": [0, 0], "MAX": [1, 1] },
            { "NAME": "mode", "TYPE": "long", "VALUES": [0, 1, 2], "LABELS": ["off", "soft", "hard"] },
            { "NAME": "on", "TYPE": "bool" }
            """), name: "Early", compiler: ISFCompiler())
        XCTAssertEqual(node.controls.map(\.code.rawValue),
                       ["x:glow", "x:tint.r", "x:tint.g", "x:tint.b", "x:tint.a", "x:centre.x", "x:centre.y", "x:mode", "x:on"],
                       "one control per scalar and per component, declared at once")

        // A value set before the program arrives is kept, by name, and survives install.
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        registry.setValue(0.9, slot: node.identifier, code: .isolated(inputName: "tint.g"))
        registry.setValue(1.4, slot: node.identifier, code: .isolated(inputName: "mode"))
        node.applyParameters(from: registry)
        XCTAssertEqual(node.value(ofInput: "tint"), [1.0, 0.9, 0.25, 1.0])
        XCTAssertEqual(node.value(ofInput: "mode"), [1], "a long snaps to its nearest VALUE")
        let mode = try XCTUnwrap(node.controls.first { $0.inputName == "mode" })
        XCTAssertEqual(mode.valueText(2), "hard")
        XCTAssertEqual(node.controls.first { $0.inputName == "on" }?.valueText(0.7), "on")
    }

    func testValuesAreClampedAndNonsenseIsRefused() throws {
        let node = try ISFTestSupport.node(effect(
            "void main() { gl_FragColor = tint * amount; }",
            inputs: """
            { "NAME": "amount", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.5 },
            { "NAME": "tint", "TYPE": "color" }
            """), metal: metal)
        node.setValue(7, forInput: "amount")
        XCTAssertEqual(node.value(ofInput: "amount"), [1.0])
        node.setValue(.nan, forInput: "amount")
        XCTAssertEqual(node.value(ofInput: "amount"), [0.5], "a non-finite value falls back to the default")
        node.setValue([1, 0], forInput: "tint")
        XCTAssertEqual(node.value(ofInput: "tint"), [0, 0, 0, 1], "wrong component count is ignored")
        node.setValue(1, forInput: "missing")
    }

    func testReinstallingKeepsValuesForInputsThatStillExist() throws {
        let first = effect("void main() { gl_FragColor = vec4(amount); }",
                           inputs: #"{ "NAME": "amount", "TYPE": "float", "DEFAULT": 0.1 }"#)
        let node = try ISFTestSupport.node(first, metal: metal)
        node.setValue(0.8, forInput: "amount")
        let edited = effect("void main() { gl_FragColor = vec4(amount * 0.5); }",
                            inputs: #"{ "NAME": "amount", "TYPE": "float", "DEFAULT": 0.1 }"#)
        node.install(try ISFProgram.compile(source: edited, name: "edited", device: metal.device))
        XCTAssertEqual(node.value(ofInput: "amount"), [0.8], "a hot reload keeps the operator's settings")
    }
}

final class ISFBuiltinFactoryTests: XCTestCase {

    func testBuiltinNodesBecomeReadyAndExposeTheNativeCodes() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        Log.echoesToStandardError = false
        let colour = ISFNode.builtin("Colour", identifier: "test.builtin.colour", context: metal)
        let missing = ISFNode.builtin("NoSuchModule", identifier: "test.builtin.missing", context: metal)
        let deadline = Date().addingTimeInterval(10)
        while colour.state == .compiling && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(colour.state, .ready)
        XCTAssertEqual(Set(colour.parameters.map(\.code)),
                       Set(ColourControlNode(identifier: "native", context: metal).parameters.map(\.code)),
                       "the port exposes exactly the native node's codes")
        guard case .failed = missing.state else { return XCTFail("a missing built-in must fail visibly") }
    }
}
