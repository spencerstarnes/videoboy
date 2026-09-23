//
//  PerChannelCostBenchmark.swift — what per-channel effects would cost.
//
//  The A/B/BOTH selector on every effect means each effect existing once per CHANNEL
//  rather than once per bus: 20 full-frame passes instead of 10. This measures one
//  pass of each so the decision is made on a number rather than a feeling.
//

import XCTest
@testable import VideoboyCore

final class PerChannelCostBenchmark: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testMeasureOnePassOfEachBusEffect() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        let bars = TestPattern.colorBars()
        guard let texture = metal.makeTexture(from: bars, label: "bench") else {
            throw XCTSkip("could not upload")
        }
        let context = RenderContext(frameIndex: 7, presentationTime: 0.2, musicalPosition: nil)

        func time(_ name: String, _ node: Node) -> Double {
            _ = node.render(inputs: [texture], context: context)   // warm
            let start = Date()
            let rounds = 30
            for _ in 0..<rounds { _ = node.render(inputs: [texture], context: context) }
            let ms = Date().timeIntervalSince(start) / Double(rounds) * 1000
            print(String(format: "[bench] per-pass %@: %.3f ms", name, ms))
            return ms
        }

        let colour = ColourControlNode(identifier: "b.colour", context: metal)
        colour.settings = ColourSettings(brightness: 0.1, contrast: 1.2, saturation: 1.1)
        let composite = CompositeCodecNode(identifier: "b.composite", context: metal)
        let echo = EchoNode(identifier: "b.echo", context: metal)
        let feedback = FeedbackNode(identifier: "b.feedback", context: metal)
        let freeze = FreezeNode(identifier: "b.freeze", context: metal)
        freeze.hold = 1

        let total = time("colour", colour)
            + time("composite", composite)
            + time("echo", echo)
            + time("feedback", feedback)
            + time("freeze", freeze)

        print(String(
            format: "one bus chain: %.2f ms — two buses %.2f ms — per-channel (4x) %.2f ms of a 33.4 ms budget",
            total, total * 2, total * 4))

        // Not an assertion about the design, just a floor: if ONE chain already eats
        // the frame, per-channel is not a trade-off, it is impossible.
        XCTAssertLessThan(total, 33.4, "a single bus chain already exceeds the frame budget")
    }
}
