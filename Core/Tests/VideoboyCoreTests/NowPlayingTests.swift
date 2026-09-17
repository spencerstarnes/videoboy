//
//  NowPlayingTests.swift — the now-playing overlay's rules.
//
//  The drawing needs a source and a screen; the RULES do not, and the rules are where
//  this would go wrong. Fade-on-change re-triggering continuously, or a track change
//  going unnoticed because progress happened to match, are both bugs you would only
//  see by watching it for several minutes.
//

import XCTest
@testable import VideoboyCore

final class NowPlayingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let track = NowPlayingTrack(
        title: "Windowlicker", artist: "Aphex Twin", album: "Windowlicker", progress: 0.2)

    // MARK: - What counts as a new track

    func testProgressMovingIsNotANewTrack() {
        var later = track
        later.progress = 0.9
        XCTAssertFalse(
            later.isDifferentTrack(from: track),
            "a track is not new because it has been playing — fade-on-change would "
                + "re-trigger every frame")
    }

    func testADifferentTitleIsANewTrack() {
        var next = track
        next.title = "Come to Daddy"
        XCTAssertTrue(next.isDifferentTrack(from: track))
    }

    func testTheFirstTrackAfterSilenceIsANewTrack() {
        XCTAssertTrue(track.isDifferentTrack(from: nil))
    }

    func testArtworkDoesNotAffectIdentity() {
        var withArt = track
        withArt.artwork = ImageBuffer(width: 8, height: 8, r: 255, g: 0, b: 0)
        XCTAssertEqual(withArt, track, "cover art is derived from the track, not part of it")
    }

    // MARK: - When the overlay is visible

    private let visibility = NowPlayingVisibility(
        holdSeconds: 5, fadeSeconds: 1, onlyOnTrackChange: true)

    func testItFadesInHoldsAndFadesOut() {
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 0), 0, accuracy: 0.01)
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 1), 1, accuracy: 0.01)
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 4), 1, accuracy: 0.01, "held")
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 6.5), 0.5, accuracy: 0.01, "fading out")
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 8), 0, accuracy: 0.01, "gone")
        XCTAssertEqual(visibility.opacity(secondsSinceChange: 600), 0, accuracy: 0.01, "stays gone")
    }

    func testAlwaysOnIgnoresTheTimings() {
        let always = NowPlayingVisibility(onlyOnTrackChange: false)
        for seconds in [0.0, 1.0, 60.0, 9999.0] {
            XCTAssertEqual(
                always.opacity(secondsSinceChange: seconds), 1, accuracy: 0.001,
                "an always-on overlay must not fade at any point")
        }
    }

    func testNonsenseTimeDoesNotProduceNonsenseOpacity() {
        XCTAssertEqual(visibility.opacity(secondsSinceChange: .nan), 0)
        XCTAssertEqual(visibility.opacity(secondsSinceChange: -5), 0)
        XCTAssertEqual(visibility.opacity(secondsSinceChange: .infinity), 0)
    }

    func testAZeroFadeIsAHardCutRatherThanADivideByZero() {
        let instant = NowPlayingVisibility(holdSeconds: 2, fadeSeconds: 0, onlyOnTrackChange: true)
        XCTAssertEqual(instant.opacity(secondsSinceChange: 0.001), 1, accuracy: 0.01)
        XCTAssertEqual(instant.opacity(secondsSinceChange: 5), 0, accuracy: 0.01)
    }

    // MARK: - Templates

    func testEveryTemplateRoundTripsThroughItsFaderPosition() {
        for template in NowPlayingTemplate.allCases {
            XCTAssertEqual(
                NowPlayingTemplate.from(normalised: template.normalisedPosition), template)
        }
    }

    func testTemplatesDifferInWhatTheyDraw() {
        // If every template answered the same, they would be one template.
        let slabs = Set(NowPlayingTemplate.allCases.map(\.hasSlab))
        let artwork = Set(NowPlayingTemplate.allCases.map(\.showsArtwork))
        XCTAssertEqual(slabs.count, 2)
        XCTAssertEqual(artwork.count, 2)
        XCTAssertFalse(NowPlayingTemplate.ticker.hasSlab, "the ticker exists to cover as little as possible")
    }

    func testTemplateSelectionSurvivesNonFiniteInput() {
        _ = NowPlayingTemplate.from(normalised: .nan)
        _ = NowPlayingTemplate.from(normalised: .infinity)
    }

    // MARK: - Sources

    func testAMockSourceStandsInForARealOne() {
        let source: NowPlayingSource = MockNowPlayingSource(track: track)
        XCTAssertTrue(source.isAvailable)
        XCTAssertEqual(source.currentTrack?.title, "Windowlicker")
    }

    func testASourceWithNothingPlayingReportsNil() {
        let source = MockNowPlayingSource()
        XCTAssertNil(source.currentTrack)
    }
}
