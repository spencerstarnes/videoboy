//
//  ISFConverterTests.swift — ISF (GLSL) → Metal, proved by compiling.
//
//  Every token rule and prelude function is exercised by a fixture, and every fixture
//  must COMPILE through `makeLibrary(source:)` — the same call the app makes. Text that
//  merely looks right is not the bar; Metal accepting it is.
//

import XCTest
import Metal
@testable import VideoboyCore

final class ISFConverterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func device() throws -> MTLDevice {
        guard let device = MetalContext.shared?.device else { throw XCTSkip("no Metal device") }
        return device
    }

    /// Wraps a GLSL body in a minimal effect header.
    private func effect(_ body: String, inputs: String = "") -> String {
        let extra = inputs.isEmpty ? "" : ",\n" + inputs
        return """
        /*{
            "INPUTS": [
                { "NAME": "inputImage", "TYPE": "image" }\(extra)
            ]
        }*/
        \(body)
        """
    }

    /// Converts and compiles, failing the test with the translated Metal error.
    @discardableResult
    private func compiles(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> ISFProgram? {
        let device = try device()
        do {
            return try ISFProgram.compile(source: source, name: "fixture", device: device)
        } catch let error as ISFCompileError {
            if case .metal(let message, _) = error {
                XCTFail("did not compile:\n\(message)", file: file, line: line)
            } else {
                XCTFail("did not compile: \(error.description)", file: file, line: line)
            }
            return nil
        }
    }

    // MARK: - The shape of the output

    func testTheSmallestEffectCompiles() throws {
        try compiles(effect("void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage); }"))
    }

    func testEveryInputTypeReachesTheShaderUnderItsOwnName() throws {
        try compiles(effect("""
        void main() {
            vec4 c = IMG_NORM_PIXEL(inputImage, isf_FragNormCoord);
            if (on) { c.rgb *= amount; }
            if (mode == 2) { c = tint; }
            c.rg += centre * 0.0;
            if (hit) { c = vec4(1.0); }
            gl_FragColor = c;
        }
        """, inputs: """
            { "NAME": "amount", "TYPE": "float" },
            { "NAME": "on", "TYPE": "bool" },
            { "NAME": "mode", "TYPE": "long", "VALUES": [1, 2] },
            { "NAME": "tint", "TYPE": "color" },
            { "NAME": "centre", "TYPE": "point2D" },
            { "NAME": "hit", "TYPE": "event" }
        """))
    }

    func testBuiltInUniformsAndCoordinatesAreInScope() throws {
        try compiles(effect("""
        void main() {
            float t = TIME + TIMEDELTA + float(FRAMEINDEX) + float(PASSINDEX) + DATE.w;
            vec2 p = gl_FragCoord.xy / RENDERSIZE + vv_FragNormCoord * 0.0;
            float beat = VB_BEAT + VB_PHASE;
            gl_FragColor = vec4(p, fract(t + beat), 1.0);
        }
        """))
    }

    func testUniformLayoutMatchesMetalsOwn() throws {
        // The generated source carries a static_assert on sizeof(ISFUniforms); compiling
        // is the check. This pins the Swift side's arithmetic too.
        let document = try ISFDocument(source: effect("void main() {}", inputs: """
            { "NAME": "a", "TYPE": "float" },
            { "NAME": "c", "TYPE": "color" },
            { "NAME": "b", "TYPE": "bool" },
            { "NAME": "p", "TYPE": "point2D" }
        """), name: "layout")
        let layout = try ISFMetalGenerator.generate(document).uniformLayout
        // TIME 0, TIMEDELTA 4, FRAMEINDEX 8, PASSINDEX 12, RENDERSIZE 16, DATE 32,
        // VB_BEAT 48, VB_PHASE 52, a 56, c 64 (aligned 16), b 80, p 88 (aligned 8) → 96.
        XCTAssertEqual(layout.field(named: "DATE")?.offset, 32)
        XCTAssertEqual(layout.field(named: "a")?.offset, 56)
        XCTAssertEqual(layout.field(named: "c")?.offset, 64)
        XCTAssertEqual(layout.field(named: "b")?.offset, 80)
        XCTAssertEqual(layout.field(named: "p")?.offset, 88)
        XCTAssertEqual(layout.size, 96)
        try compiles(effect("void main() { gl_FragColor = c * a; }", inputs: """
            { "NAME": "a", "TYPE": "float" },
            { "NAME": "c", "TYPE": "color" },
            { "NAME": "b", "TYPE": "bool" },
            { "NAME": "p", "TYPE": "point2D" }
        """))
    }

    // MARK: - Token rules, one fixture each

    func testMutableAndConstantGlobals() throws {
        try compiles(effect("""
        const float PI = 3.14159265;
        float counter = 0.0;
        vec2 offset;
        void bump() { counter += 1.0; }
        void main() {
            bump();
            offset = vec2(counter / PI);
            gl_FragColor = vec4(offset, 0.0, 1.0);
        }
        """))
    }

    func testInOutAndInoutParameters() throws {
        try compiles(effect("""
        void wobble(inout vec2 uv, in float amount, out float used) {
            uv.x += sin(uv.y * 10.0) * amount;
            used = amount;
        }
        void main() {
            vec2 uv = isf_FragNormCoord;
            float used;
            wobble(uv, 0.1, used);
            gl_FragColor = IMG_NORM_PIXEL(inputImage, uv) * used;
        }
        """))
    }

    func testForwardDeclarationsAreDropped() throws {
        try compiles(effect("""
        float shade(vec2 p);
        vec3 tintOf(float t);
        void main() { gl_FragColor = vec4(tintOf(shade(isf_FragNormCoord)), 1.0); }
        float shade(vec2 p) { return p.x * p.y; }
        vec3 tintOf(float t) { return vec3(t); }
        """))
    }

    func testVersionPrecisionUniformAndExtensionAreDropped() throws {
        try compiles(effect("""
        #version 120
        #extension GL_OES_standard_derivatives : enable
        #ifdef GL_ES
        precision mediump float;
        #endif
        uniform float amount;
        void main() { highp vec4 c = IMG_THIS_PIXEL(inputImage); gl_FragColor = c * amount; }
        """, inputs: #"{ "NAME": "amount", "TYPE": "float" }"#))
    }

    func testGLSL3OutputDeclarationBecomesGlFragColor() throws {
        try compiles(effect("""
        out vec4 fragColor;
        void main() { fragColor = IMG_THIS_PIXEL(inputImage); }
        """))
    }

    func testArrayConstructors() throws {
        try compiles(effect("""
        const float weights[3] = float[3](0.25, 0.5, 0.25);
        void main() {
            vec2 offsets[2] = vec2[](vec2(-0.01, 0.0), vec2(0.01, 0.0));
            vec4 sum = vec4(0.0);
            for (int i = 0; i < 2; i++) {
                sum += IMG_NORM_PIXEL(inputImage, isf_FragNormCoord + offsets[i]) * weights[i];
            }
            gl_FragColor = sum;
        }
        """))
    }

    func testMetalKeywordsUsedAsNamesAreRenamed() throws {
        try compiles(effect("""
        float constant = 0.5;
        float sampler(float kernel) { return kernel * 2.0; }
        void main() {
            float vertex = sampler(constant);
            gl_FragColor = texture(inputImage, isf_FragNormCoord) * vertex;
        }
        """))
    }

    func testSTPQSwizzlesAndTexture2D() throws {
        try compiles(effect("""
        void main() {
            vec2 st = isf_FragNormCoord.st;
            vec4 c = texture2D(inputImage, st);
            gl_FragColor = vec4(c.stp, c.q);
        }
        """))
    }

    func testGLSLBuiltInsMetalLacks() throws {
        try compiles(effect("""
        void main() {
            vec2 p = isf_FragNormCoord;
            float a = atan(p.y - 0.5, p.x - 0.5) + atan(p.x);
            vec3 m = mod(vec3(p, a), 0.25) + mod(vec3(1.0), vec3(0.3));
            float r = radians(degrees(a)) + inversesqrt(1.0 + p.x);
            bvec2 lt = lessThan(p, vec2(0.5));
            if (any(lt) && all(greaterThanEqual(p, vec2(0.0)))) { m += 0.1; }
            vec2 size = IMG_SIZE(inputImage);
            vec4 px = IMG_PIXEL(inputImage, gl_FragCoord.xy) + texture2DRect(inputImage, size * 0.5);
            float edge = dFdx(p.x) + dFdy(p.y);
            if (r < -100.0) { discard; }
            gl_FragColor = vec4(m, 1.0) * px + edge;
        }
        """))
    }

    func testMatrices() throws {
        try compiles(effect("""
        void main() {
            float a = TIME;
            mat2 rotate = mat2(cos(a), -sin(a), sin(a), cos(a));
            vec2 p = rotate * (isf_FragNormCoord - 0.5) + 0.5;
            mat3 identity = mat3(1.0);
            gl_FragColor = vec4(identity * IMG_NORM_PIXEL(inputImage, p).rgb, 1.0);
        }
        """))
    }

    func testMultiPassPersistentAndFloatBuffers() throws {
        try compiles("""
        /*{
            "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ],
            "PASSES": [
                { "TARGET": "small", "WIDTH": "$WIDTH/4", "HEIGHT": "$HEIGHT/4" },
                { "TARGET": "accum", "PERSISTENT": true, "FLOAT": true },
                { }
            ]
        }*/
        void main() {
            if (PASSINDEX == 0) {
                gl_FragColor = IMG_THIS_PIXEL(inputImage);
            } else if (PASSINDEX == 1) {
                gl_FragColor = mix(IMG_THIS_PIXEL(accum), IMG_THIS_PIXEL(small), 0.1);
            } else {
                gl_FragColor = IMG_THIS_PIXEL(accum);
            }
        }
        """)
    }

    func testAGeneratorCompiles() throws {
        try compiles("""
        /*{ "INPUTS": [ { "NAME": "speed", "TYPE": "float", "DEFAULT": 1.0 } ] }*/
        void main() {
            vec2 p = isf_FragNormCoord;
            gl_FragColor = vec4(fract(p.x + TIME * speed), p.y, 0.5, 1.0);
        }
        """)
    }

    // MARK: - Failing visibly

    func testMetalErrorsPointAtTheAuthorsLine() throws {
        let device = try device()
        // Line 7 of this file has the mistake: `vec3` assigned to a float.
        let source = """
        /*{
            "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ]
        }*/

        void main() {
            vec4 c = IMG_THIS_PIXEL(inputImage);
            float broken = c.rgb;
            gl_FragColor = c;
        }
        """
        XCTAssertThrowsError(try ISFProgram.compile(source: source, name: "broken", device: device)) { error in
            guard case .metal(let message, let firstError) = error as? ISFCompileError else {
                return XCTFail("expected a Metal error, got \(error)")
            }
            XCTAssertTrue(firstError.hasPrefix("line 7:"), "first error was: \(firstError)")
            XCTAssertFalse(message.contains("program_source:"), "every line is translated")
        }
    }

    func testUnsupportedFeaturesAreNamed() throws {
        let varying = effect("varying vec2 left;\nvoid main() { gl_FragColor = vec4(left, 0.0, 1.0); }")
        XCTAssertThrowsError(try ISFMetalGenerator.generate(ISFDocument(source: varying, name: "v"))) {
            guard case .unsupported(let what) = $0 as? ISFGenerateError else { return XCTFail("\($0)") }
            XCTAssertTrue(what.contains("vertex shader"))
        }
        let imported = #"/*{ "IMPORTED": { "noise": { "PATH": "noise.png" } } }*/ void main() {}"#
        XCTAssertThrowsError(try ISFMetalGenerator.generate(ISFDocument(source: imported, name: "i"))) {
            guard case .unsupported(let what) = $0 as? ISFGenerateError else { return XCTFail("\($0)") }
            XCTAssertTrue(what.contains("IMPORTED"))
        }
        let audio = #"/*{ "INPUTS": [ { "NAME": "sound", "TYPE": "audioFFT" } ] }*/ void main() {}"#
        XCTAssertThrowsError(try ISFMetalGenerator.generate(ISFDocument(source: audio, name: "a")))
    }

    func testRewritingNeverMovesALine() throws {
        let body = """
        #version 120
        precision highp float;
        uniform float x;
        float f(float a);
        void g(inout vec2 p,
               out float q) { q = 1.0; }
        const float w[2] = float[2](1.0,
                                    2.0);
        float f(float a) { return a; }
        void main() {}
        """
        let rewritten = try ISFMetalGenerator.rewriteBody(GLSLTokenizer.tokenize(body)).text
        XCTAssertEqual(rewritten.filter { $0 == "\n" }.count, body.filter { $0 == "\n" }.count)
        XCTAssertTrue(rewritten.contains("thread vec2& p"))
        XCTAssertTrue(rewritten.contains("thread float& q"))
        XCTAssertFalse(rewritten.contains("precision"))
        XCTAssertFalse(rewritten.contains("uniform"))
    }

    func testMatrixCompoundAssignment() throws {
        // GLSL allows `m *= r` and `v *= m`; Metal only has the binary operators.
        // Found in a real VDMX pack ("Broken Tesseract": mat *= mat4(...)).
        try compiles(effect("""
        mat4 spin = mat4(1.0);
        void main() {
            mat2 a = mat2(1.0);  a *= mat2(0.0, 1.0, -1.0, 0.0);
            mat3 b = mat3(1.0);  b *= mat3(2.0);
            spin *= mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0),
                         vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
            vec2 p = isf_FragNormCoord;  p *= a;
            vec3 q = vec3(p, 1.0);       q *= b;
            vec4 r = vec4(q, 1.0);       r *= spin;
            gl_FragColor = r;
        }
        """))
    }

    func testWindowsAndClassicMacLineEndingsStillMapErrorsToTheAuthorsLine() throws {
        let device = try device()
        // Swift reads "\r\n" as ONE Character, so counting "\n" Characters saw no
        // lines at all in a CRLF file and every error came back as "generated line".
        let lines = [
            "/*{",
            "    \"INPUTS\": [ { \"NAME\": \"inputImage\", \"TYPE\": \"image\" } ]",
            "}*/",
            "#version 120",
            "void main() {",
            "    vec4 c = IMG_THIS_PIXEL(inputImage);",
            "    float broken = c.rgb;",
            "    gl_FragColor = c;",
            "}"
        ]
        for (label, separator) in [("CRLF", "\r\n"), ("CR", "\r")] {
            let source = lines.joined(separator: separator)
            XCTAssertThrowsError(try ISFProgram.compile(source: source, name: label, device: device)) { error in
                guard case .metal(_, let firstError) = error as? ISFCompileError else {
                    return XCTFail("\(label): expected a Metal error, got \(error)")
                }
                XCTAssertTrue(firstError.hasPrefix("line 7:"), "\(label): first error was \(firstError)")
            }
        }
    }

    // MARK: - The built-ins

    func testEveryBuiltinModuleCompiles() throws {
        let entries = ISFLibrary.scan([(ISFLibrary.builtinFolder, .builtin)])
        XCTAssertEqual(Set(entries.map(\.name)), ["Colour", "Echo", "Transform"])
        for entry in entries {
            guard let source = entry.source else { XCTFail("\(entry.name) unreadable"); continue }
            let program = try compiles(source)
            XCTAssertEqual(program?.document.kind, .effect, entry.name)
            // Every value input declares a code that exists, so the registry can reach it.
            for input in program?.document.valueInputs ?? [] {
                XCTAssertNotNil(input.videoboyCode.flatMap(ParamCode.init(rawValue:)),
                                "\(entry.name).\(input.name) has no valid VIDEOBOY_CODE")
            }
        }
    }
}
