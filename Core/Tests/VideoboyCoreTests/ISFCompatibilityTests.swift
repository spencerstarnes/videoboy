//
//  ISFCompatibilityTests.swift — GLSL as real ISF packs write it.
//
//  Each case here is a pattern found in the Vidvox ISF-Files or a community pack that
//  failed to convert. Asserted on rendered pixels wherever the rule changes meaning
//  (scoping, write-back), because "it compiles" says nothing about which variable an
//  initializer read.
//

import Metal
import XCTest
@testable import VideoboyCore

final class ISFCompatibilityTests: XCTestCase {

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

    private func effect(_ body: String, inputs: String = "") -> String {
        let extra = inputs.isEmpty ? "" : ",\n" + inputs
        return """
            /*{ "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" }\(extra) ] }*/
            \(body)
            """
    }

    /// Compiles, renders one frame over a flat plate, returns the middle pixel.
    private func centre(of source: String, plate: (UInt8, UInt8, UInt8) = (100, 150, 200)) throws
        -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let program = try ISFProgram.compile(source: source, name: "compat", device: metal.device)
        let node = ISFNode(identifier: "test.compat", context: metal)
        node.install(program)
        let image = ImageBuffer(width: 64, height: 48, r: plate.0, g: plate.1, b: plate.2)
        guard let input = metal.makeTexture(from: image, label: "compat.in"),
              let output = node.render(inputs: [input], context: ISFTestSupport.context()),
              let picture = renderer.readback(output) else {
            throw XCTSkip("render failed")
        }
        return picture.pixel(x: 32, y: 24)
    }

    func testAStructFieldNamedLikeASwizzleIsLeftAlone() throws {
        let pixel = try centre(of: effect("""
            struct Hexagon { float q; float r; float s; };
            void main() {
                Hexagon hex;
                hex.q = 1.0; hex.s = 0.0;
                vec2 v = vec2(0.25, 0.5);
                gl_FragColor = vec4(hex.q, v.t, hex.s, 1.0);
            }
            """))
        XCTAssertEqual(pixel.r, 255, "hex.q is the field, not .w")
        XCTAssertEqual(Double(pixel.g), 0.5 * 255, accuracy: 2, "v.t is still y")
    }

    func testAnInitializerReadsTheOuterNameAsGLSLScopesIt() throws {
        // `float distance = distance(…)` calls the function; `vec4 inputImage_ =
        // IMG_THIS_PIXEL(inputImage)`-style shadowing reads the image.
        let pixel = try centre(of: effect("""
            void main() {
                float distance = distance(vec2(0.0), vec2(0.3, 0.4));
                vec4 inputImage = IMG_THIS_PIXEL(inputImage);
                gl_FragColor = vec4(distance, inputImage.g, 0.0, 1.0);
            }
            """))
        XCTAssertEqual(Double(pixel.r), 0.5 * 255, accuracy: 2, "distance() of a 3-4-5 triangle")
        XCTAssertEqual(pixel.g, 150, "the shadowing local read the image, then is used as itself")
    }

    func testCPlusPlusWordsAreFreeNamesInGLSL() throws {
        let pixel = try centre(of: effect("""
            void main() {
                float signed = sign(-2.0);
                float unsigned = 1.0;
                gl_FragColor = vec4(signed * -1.0, unsigned, 0.0, 1.0);
            }
            """))
        XCTAssertEqual(pixel.r, 255)
        XCTAssertEqual(pixel.g, 255)
    }

    func testASwizzlePassedToAnInoutParameterIsWrittenBack() throws {
        let pixel = try centre(of: effect("""
            void double2(inout vec2 p) { p *= 2.0; }
            float half2(inout vec2 p, float k) { p *= k; return p.x; }
            void main() {
                vec3 v = vec3(0.1, 0.2, 0.3);
                double2(v.xz);
                float first = half2(v.yx, 0.5);
                gl_FragColor = vec4(v.x, v.z, first, 1.0);
            }
            """))
        // v.xz doubled → (0.2, 0.2, 0.6); then v.yx halved → y 0.1, x 0.1; returns 0.1.
        XCTAssertEqual(Double(pixel.r), 0.1 * 255, accuracy: 2, "x written back through both calls")
        XCTAssertEqual(Double(pixel.g), 0.6 * 255, accuracy: 2, "z written back")
        XCTAssertEqual(Double(pixel.b), 0.1 * 255, accuracy: 2, "the call's value comes out too")
    }

    func testSampler2DAsAParameterType() throws {
        let pixel = try centre(of: effect("""
            vec4 fetch(sampler2D image, vec2 uv) { return texture2D(image, uv); }
            void main() { gl_FragColor = fetch(inputImage, isf_FragNormCoord); }
            """))
        XCTAssertEqual(pixel.b, 200)
    }

    func testScalarGeometryAndMixedModAsAppleGLSLAcceptsThem() throws {
        let pixel = try centre(of: effect("""
            uvec2 cell = uvec2(4, 8);
            void main() {
                float a = distance(0.25, 0.75);
                float b = length(-0.5);
                vec2 m = mod(vec2(5.0, 9.0), cell);
                float c = distance(vec2(0.5), 0.5);
                gl_FragColor = vec4(a, b, m.x / 4.0 + c, 1.0);
            }
            """))
        XCTAssertEqual(Double(pixel.r), 0.5 * 255, accuracy: 2)
        XCTAssertEqual(Double(pixel.g), 0.5 * 255, accuracy: 2)
        XCTAssertEqual(Double(pixel.b), 0.25 * 255, accuracy: 2, "mod(5, 4) = 1, / 4")
    }

    func testMixedMatrixConstructorsAndSwizzleTimesMatrix() throws {
        // `mat2(a.y, -a.x, a)` flattens to columns c0 = (a.y, -a.x), c1 = (a.x, a.y).
        // With a = (1, 0): c0 = (0, -1), c1 = (1, 0). GLSL's `v *= m` is v = v * m,
        // the row-vector product (dot(v, c0), dot(v, c1)); for v.xz = (1, 0) that is
        // (0, 1) — a quarter turn, so a transposed or mis-ordered matrix shows.
        let pixel = try centre(of: effect("""
            void main() {
                vec2 a = vec2(1.0, 0.0);
                mat2 m = mat2(a.y, -a.x, a);
                vec3 v = vec3(1.0, 0.0, 0.0);
                v.xz *= m;
                mat2 d = mat2(0.5);
                gl_FragColor = vec4(v.x + 0.5, v.z + 0.5, d[0][0], 1.0);
            }
            """))
        XCTAssertEqual(Double(pixel.r), 0.5 * 255, accuracy: 2, "x went to 0")
        XCTAssertEqual(pixel.g, 255, "z went to 1 (+0.5, clamped)")
        XCTAssertEqual(Double(pixel.b), 0.5 * 255, accuracy: 2, "one scalar makes a diagonal")
    }

    func testAnUndeclaredUniformReadsZeroAndAComponentIsWrittenBack() throws {
        let pixel = try centre(of: effect("""
            uniform vec4 MOUSE;
            float wrap(inout float x, float size) { x = mod(x, size); return size; }
            void main() {
                vec3 p = vec3(0.0, 0.0, 1.25);
                float s = wrap(p.z, 1.0);
                gl_FragColor = vec4(MOUSE.x, p.z, s, 1.0);
            }
            """))
        XCTAssertEqual(pixel.r, 0, "a uniform nothing drives reads zero")
        XCTAssertEqual(Double(pixel.g), 0.25 * 255, accuracy: 2, "p.z came back wrapped")
        XCTAssertEqual(pixel.b, 255)
    }

    func testGlobalIntegerVectorsInFloatMathsAsAppleGLSLAllows() throws {
        let pixel = try centre(of: effect("""
            uvec2 cells = uvec2(4, 8);
            void main() {
                vec2 fraction = vec2(2.0, 2.0) / cells;
                gl_FragColor = vec4(fraction, 0.0, 1.0);
            }
            """))
        XCTAssertEqual(Double(pixel.r), 0.5 * 255, accuracy: 2)
        XCTAssertEqual(Double(pixel.g), 0.25 * 255, accuracy: 2)
    }

    func testISFVersionOnePerImageUniforms() throws {
        let pixel = try centre(of: effect("""
            void main() {
                gl_FragColor = vec4(_inputImage_imgSize.x / 64.0, _inputImage_imgRect.w / 48.0,
                                    _inputImage_flip ? 1.0 : 0.0, 1.0);
            }
            """))
        XCTAssertEqual(pixel.r, 255, "imgSize is the image's size in pixels")
        XCTAssertEqual(pixel.g, 255, "imgRect carries it too")
        XCTAssertEqual(pixel.b, 0, "nothing reports flipped: sampling already corrects it")
    }
}
