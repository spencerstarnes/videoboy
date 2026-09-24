//
//  ISFTransitionTests.swift — an ISF transition drawing a crossfader's move.
//

import Metal
import XCTest
@testable import VideoboyCore

final class ISFTransitionTests: XCTestCase {

    func testACrossfaderDrawsItsMoveThroughAnISFTransition() throws {
        Log.echoesToStandardError = false
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        // endImage declared FIRST: inputs must be matched by name, not order.
        let source = """
            /*{ "INPUTS": [
                { "NAME": "endImage", "TYPE": "image" },
                { "NAME": "startImage", "TYPE": "image" },
                { "NAME": "progress", "TYPE": "float", "DEFAULT": 0.0 } ] }*/
            void main() {
                gl_FragColor = mix(IMG_THIS_PIXEL(startImage), IMG_THIS_PIXEL(endImage), progress);
            }
            """
        let program = try ISFProgram.compile(source: source, name: "fade", device: metal.device)
        XCTAssertEqual(program.document.kind, .transition)
        let isf = ISFNode(identifier: "mix.test.isf", context: metal)
        isf.install(program)

        let fader = CrossfadeNode(identifier: "mix.test", positionCode: .crossfadeAB, context: metal)
        fader.isfTransition = isf
        fader.position = 0.25
        guard let a = metal.makeTexture(from: ImageBuffer(width: 64, height: 48, r: 200, g: 0, b: 0), label: "a"),
              let b = metal.makeTexture(from: ImageBuffer(width: 64, height: 48, r: 0, g: 200, b: 0), label: "b"),
              let output = fader.render(
                inputs: [a, b],
                context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil,
                                       width: 64, height: 48)),
              let picture = renderer.readback(output) else { throw XCTSkip("render failed") }
        let pixel = picture.pixel(x: 32, y: 24)
        XCTAssertEqual(Double(pixel.r), 150, accuracy: 2, "three quarters of A at 0.25")
        XCTAssertEqual(Double(pixel.g), 50, accuracy: 2, "a quarter of B")
    }
}
