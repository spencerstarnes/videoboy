//
//  ISFVertexShaderTests.swift — custom `.vs` files: geometry moves, varyings arrive.
//
//  Asserted on rendered pixels, not on generated text: a vertex stage that compiles
//  but hands the fragment zeros would pass any test that only looked at the source.
//

import Metal
import XCTest
@testable import VideoboyCore

final class ISFVertexShaderTests: XCTestCase {

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

    private func render(fragment: String, vertex: String, input: ImageBuffer? = nil) throws -> ImageBuffer {
        let program = try ISFProgram.compile(
            source: fragment, vertexSource: vertex, name: "vs-test", device: metal.device)
        XCTAssertTrue(program.shader.hasVertexShader)
        let node = ISFNode(identifier: "test.vs", context: metal)
        node.install(program)
        let plate = input ?? ImageBuffer(width: 120, height: 80, r: 255, g: 255, b: 255)
        guard let texture = metal.makeTexture(from: plate, label: "vs.in"),
              let output = node.render(inputs: [texture], context: ISFTestSupport.context()),
              let picture = renderer.readback(output) else {
            throw XCTSkip("render failed")
        }
        return picture
    }

    func testAVertexShaderThatShrinksTheQuadLeavesABorder() throws {
        let fragment = """
            /*{ "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ] }*/
            void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage); }
            """
        let vertex = """
            void main() {
                isf_vertShaderInit();
                gl_Position.xy *= 0.5;
            }
            """
        let picture = try render(fragment: fragment, vertex: vertex)
        XCTAssertEqual(picture.pixel(x: 60, y: 40).r, 255, "the middle is drawn")
        XCTAssertEqual(picture.pixel(x: 5, y: 5).a, 0, "the corner is outside the shrunken quad")
        XCTAssertEqual(picture.pixel(x: 115, y: 75).a, 0)
    }

    func testAVaryingIsInterpolatedAcrossTheFrame() throws {
        // The vertex writes x + 0.25 per corner; the fragment must see it interpolated,
        // so the left edge reads ~0.25 and the middle ~0.75.
        let fragment = """
            /*{ "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ] }*/
            varying vec2 shifted;
            varying float rows[2];
            void main() { gl_FragColor = vec4(shifted.x, rows[1], 0.0, 1.0); }
            """
        let vertex = """
            varying vec2 shifted;
            varying float rows[2];
            void main() {
                isf_vertShaderInit();
                shifted = isf_FragNormCoord + vec2(0.25, 0.0);
                rows[0] = 0.0;
                rows[1] = 0.5;
            }
            """
        let picture = try render(fragment: fragment, vertex: vertex)
        XCTAssertEqual(Double(picture.pixel(x: 0, y: 40).r), 0.25 * 255, accuracy: 6)
        XCTAssertEqual(Double(picture.pixel(x: 60, y: 40).r), 0.75 * 255, accuracy: 6)
        XCTAssertEqual(Double(picture.pixel(x: 60, y: 40).g), 0.5 * 255, accuracy: 3,
                       "an array varying's element arrives")
    }

    func testAVertexShaderCanSampleAnImage() throws {
        // The Vidvox convolution filters compute neighbour coordinates in the .vs and
        // sample in the .fs; some sample in the .vs too, which needs an explicit LOD.
        let fragment = """
            /*{ "INPUTS": [ { "NAME": "inputImage", "TYPE": "image" } ] }*/
            varying vec4 seen;
            void main() { gl_FragColor = seen; }
            """
        let vertex = """
            varying vec4 seen;
            void main() {
                isf_vertShaderInit();
                seen = IMG_NORM_PIXEL(inputImage, vec2(0.5, 0.5));
            }
            """
        let picture = try render(
            fragment: fragment, vertex: vertex,
            input: ImageBuffer(width: 120, height: 80, r: 200, g: 40, b: 10))
        XCTAssertEqual(Double(picture.pixel(x: 60, y: 40).r), 200, accuracy: 3)
    }

    func testAVaryingWithNoVertexShaderIsRefusedByName() {
        let fragment = """
            /*{ "INPUTS": [] }*/
            varying vec2 lost;
            void main() { gl_FragColor = vec4(lost, 0.0, 1.0); }
            """
        XCTAssertThrowsError(try ISFProgram.compile(source: fragment, name: "orphan", device: metal.device)) {
            XCTAssertTrue("\($0)".contains("lost"), "\($0)")
        }
    }
}
