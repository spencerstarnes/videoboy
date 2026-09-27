//
//  NowPlayingGeneratorTests.swift — the Now Playing generator draws the track.
//

import XCTest
@testable import VideoboyCore

final class NowPlayingGeneratorTests: XCTestCase {

    private func track() -> NowPlayingTrack {
        NowPlayingTrack(title: "Bizarre Love Triangle", artist: "New Order", album: "Brotherhood",
                        progress: 0.4, artwork: ImageBuffer(width: 64, height: 64, r: 200, g: 40, b: 40))
    }

    func testEveryLookDrawsTextOnBlack() {
        for template in NowPlayingTemplate.allCases {
            let image = NowPlayingRenderer.render(track(), status: "Apple Music", template: template,
                                                  opacity: 1, showsProgress: true)
            XCTAssertEqual(image.width, 720)
            XCTAssertTrue(FrameAssertions.signalPresent(image, varianceThreshold: 1.0), "\(template) drew nothing")
            XCTAssertEqual(image.pixels[0], 0, "\(template): the corner stays black, to key over a mix")
        }
    }

    func testFadedOutIsBlackAndNothingPlayingSaysSo() {
        let hidden = NowPlayingRenderer.render(track(), status: "x", template: .lowerThird, opacity: 0, showsProgress: true)
        XCTAssertFalse(FrameAssertions.signalPresent(hidden, varianceThreshold: 0.5))
        let idle = NowPlayingRenderer.render(nil, status: "Music not running", template: .lowerThird,
                                             opacity: 1, showsProgress: true)
        XCTAssertTrue(FrameAssertions.signalPresent(idle, varianceThreshold: 1.0))
    }

    func testTheHubRestartsTheFadeOnlyOnANewTrack() {
        let hub = NowPlayingHub()
        hub.publish(track(), status: "ok", at: 10)
        var moved = track(); moved.progress = 0.5
        hub.publish(moved, status: "ok", at: 20)
        XCTAssertEqual(hub.snapshot().changedAt, 10, "progress alone is not a new track")
        hub.publish(NowPlayingTrack(title: "Other"), status: "ok", at: 30)
        XCTAssertEqual(hub.snapshot().changedAt, 30)
    }

    func testTheGeneratorRendersTheHubsTrack() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal") }
        let node = GeneratorSourceNode(identifier: "gen.test", context: metal)
        node.generator = .nowPlaying
        node.nowPlayingHub = NowPlayingHub()
        node.nowPlayingHub.publish(track(), status: "ok", at: 0)
        XCTAssertTrue(node.parameters.contains { $0.code == .nowPlayingTemplate })
        let texture = node.render(inputs: [], context: RenderContext(frameIndex: 0, presentationTime: 1, musicalPosition: nil))
        XCTAssertNotNil(texture)
        let again = node.render(inputs: [], context: RenderContext(frameIndex: 1, presentationTime: 1.03, musicalPosition: nil))
        XCTAssertTrue(texture === again, "nothing changed: the same texture, no redraw")
    }
}
