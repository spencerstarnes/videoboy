//
//  MPEGCorruptorTests.swift — the MPEG half of the wedge, on a real bitstream.
//
//  The DV corruptor has had tests since Phase 1. These are the equivalent for MPEG,
//  and they are checked against a genuine MPEG-2 elementary stream because the whole
//  feature is about real bitstream structure — a synthetic buffer would prove the
//  arithmetic and nothing about whether the format was understood.
//
//  The load-bearing claim throughout is that damaged output STILL DECODES. A stream
//  that fails to decode is a bug, not an effect: the point is a picture that is
//  wrong, not an error.
//

import XCTest
@testable import VideoboyCore

final class MPEGCorruptorTests: XCTestCase {

    private func streamBytes() throws -> [UInt8] {
        let url = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.m2v is missing — run scripts/make-fixtures.sh")
        }
        // One GOP's worth is plenty and keeps these fast.
        return Array(try Data(contentsOf: url).prefix(600_000))
    }

    // MARK: - Reading the structure

    func testStartCodesAreFound() throws {
        let bytes = try streamBytes()
        let markers = MPEGFormat.markers(in: bytes)
        XCTAssertGreaterThan(markers.count, 10, "a real stream is full of start codes")
        XCTAssertTrue(
            markers.contains { $0.code == .sequenceHeader },
            "an elementary stream should open with a sequence header")
        XCTAssertTrue(markers.contains { $0.code.isSlice }, "pictures are made of slices")
    }

    func testPicturesAreFoundWithTheirTypes() throws {
        let bytes = try streamBytes()
        let pictures = MPEGFormat.pictures(in: bytes)
        XCTAssertGreaterThan(pictures.count, 2)

        let types = Set(pictures.map(\.type))
        XCTAssertTrue(types.contains(.intra), "a GOP starts with an I picture")
        XCTAssertTrue(
            types.contains(.predicted) || types.contains(.bidirectional),
            "the fixture was encoded with B-frames, so there must be predicted pictures")

        // Every picture must be a sane, non-overlapping extent.
        for picture in pictures {
            XCTAssertGreaterThan(picture.byteCount, 0)
            XCTAssertLessThanOrEqual(picture.end, bytes.count)
            XCTAssertFalse(picture.sliceOffsets.isEmpty, "a picture is made of slices")
        }
    }

    // MARK: - The modes

    func testZeroAmountChangesNothing() throws {
        let bytes = try streamBytes()
        for mode in MPEGCorruptionMode.allCases {
            let result = MPEGCorruptor.corrupt(
                stream: bytes, settings: MPEGCorruptionSettings(amount: 0, mode: mode))
            XCTAssertEqual(result, bytes, "\(mode.rawValue) at zero must be a no-op")
        }
    }

    func testTheSameSeedGivesTheSameDamage() throws {
        let bytes = try streamBytes()
        for mode in MPEGCorruptionMode.allCases {
            let settings = MPEGCorruptionSettings(amount: 0.7, mode: mode, seed: 4242)
            let first = MPEGCorruptor.corrupt(stream: bytes, settings: settings,
                                              previousPicture: Array(bytes.prefix(2000)))
            let second = MPEGCorruptor.corrupt(stream: bytes, settings: settings,
                                               previousPicture: Array(bytes.prefix(2000)))
            XCTAssertEqual(
                first, second,
                "\(mode.rawValue) must be repeatable — a performance has to be repeatable")
        }
    }

    func testADifferentSeedGivesDifferentDamage() throws {
        let bytes = try streamBytes()
        let first = MPEGCorruptor.corrupt(
            stream: bytes, settings: MPEGCorruptionSettings(amount: 0.8, mode: .frameDrop, seed: 1))
        let second = MPEGCorruptor.corrupt(
            stream: bytes, settings: MPEGCorruptionSettings(amount: 0.8, mode: .frameDrop, seed: 2))
        XCTAssertNotEqual(first, second, "reseeding on the beat has to change the damage")
    }

    /// Frame drop removes predicted pictures and keeps the intra ones.
    ///
    /// Sparing I pictures is what makes this performable rather than a fault: they
    /// are what the decoder recovers on, so a stream without them never resynchronises
    /// and the picture stays broken instead of breaking and healing.
    func testFrameDropRemovesPredictedPicturesAndSparesIntraOnes() throws {
        let bytes = try streamBytes()
        let before = MPEGFormat.pictures(in: bytes)
        let intraBefore = before.filter { $0.type == .intra }.count

        let damaged = MPEGCorruptor.corrupt(
            stream: bytes,
            settings: MPEGCorruptionSettings(amount: 1.0, mode: .frameDrop, seed: 7))
        let after = MPEGFormat.pictures(in: damaged)

        XCTAssertLessThan(damaged.count, bytes.count, "dropping pictures should shorten the stream")
        XCTAssertLessThan(after.count, before.count, "pictures should be gone")
        XCTAssertEqual(
            after.filter { $0.type == .intra }.count, intraBefore,
            "every intra picture must survive, or the stream never recovers")
        XCTAssertEqual(
            after.filter { $0.type != .intra }.count, 0,
            "at full amount every predicted picture should have gone")
    }

    func testMotionVectorCorruptionKeepsTheStreamTheSameLength() throws {
        let bytes = try streamBytes()
        let damaged = MPEGCorruptor.corrupt(
            stream: bytes,
            settings: MPEGCorruptionSettings(amount: 1.0, mode: .motionVector, seed: 3))
        XCTAssertEqual(
            damaged.count, bytes.count,
            "scrambling edits in place; only frame drop changes the length")
        XCTAssertNotEqual(damaged, bytes, "something should have changed")
    }

    /// Scrambling must never damage a start code, or the decoder skips the rest of
    /// the picture instead of mis-decoding it — and mis-decoding is the point.
    func testMotionVectorCorruptionLeavesEveryStartCodeIntact() throws {
        let bytes = try streamBytes()
        let before = MPEGFormat.markers(in: bytes).map(\.offset)
        let damaged = MPEGCorruptor.corrupt(
            stream: bytes,
            settings: MPEGCorruptionSettings(amount: 1.0, mode: .motionVector, seed: 11))
        let after = MPEGFormat.markers(in: damaged).map(\.offset)
        XCTAssertEqual(before, after, "the start codes must be exactly where they were")
    }

    func testReferenceHoldSubstitutesThePreviousPicture() throws {
        let bytes = try streamBytes()
        guard let previous = MPEGCorruptor.lastPicture(in: bytes) else {
            return XCTFail("no picture to hold")
        }
        let damaged = MPEGCorruptor.corrupt(
            stream: bytes,
            settings: MPEGCorruptionSettings(amount: 1.0, mode: .referenceHold, seed: 5),
            previousPicture: previous)
        XCTAssertNotEqual(damaged, bytes)
        XCTAssertFalse(MPEGFormat.pictures(in: damaged).isEmpty, "it is still a stream of pictures")
    }

    func testReferenceHoldWithNothingHeldPassesThrough() throws {
        let bytes = try streamBytes()
        let damaged = MPEGCorruptor.corrupt(
            stream: bytes,
            settings: MPEGCorruptionSettings(amount: 1.0, mode: .referenceHold, seed: 5),
            previousPicture: nil)
        XCTAssertEqual(damaged, bytes, "the first frame has nothing to hold")
    }

    // MARK: - The claim that matters

    /// Every mode must produce a stream libavcodec can still decode into a picture.
    func testDamagedStreamsStillDecode() throws {
        let bytes = try streamBytes()
        let previous = MPEGCorruptor.lastPicture(in: bytes)

        for mode in MPEGCorruptionMode.allCases {
            let damaged = MPEGCorruptor.corrupt(
                stream: bytes,
                settings: MPEGCorruptionSettings(amount: 0.8, mode: mode, seed: 9),
                previousPicture: previous)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("videoboy-\(mode.rawValue)-\(UUID().uuidString).m2v")
            try Data(damaged).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            guard let decoder = MPEGStreamDecoder(url: url) else {
                XCTFail("\(mode.rawValue) produced a stream that would not even open")
                continue
            }
            let frame = decoder.image(at: 2, corruption: .inert)
            XCTAssertNotNil(
                frame,
                "\(mode.rawValue) must leave a decodable stream — a picture that is wrong, "
                    + "not an error")
        }
    }

    func testModeSelectionRoundTripsThroughAParameter() {
        for mode in MPEGCorruptionMode.allCases {
            XCTAssertEqual(
                MPEGCorruptionMode.from(normalised: mode.normalisedPosition), mode,
                "\(mode.rawValue) must come back from its own position on the fader")
        }
    }
}

extension MPEGCorruptorTests {
    /// Sanity: the UNDAMAGED fixture must open, or the failures above are about the
    /// build's demuxers rather than about the corruptor.
    func testTheUndamagedFixtureOpens() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.m2v is missing")
        }
        XCTAssertNotNil(MPEGStreamDecoder(url: url), "the clean fixture should open")
    }
}

extension MPEGCorruptorTests {
    /// A raw elementary stream carries no timestamps, so the frame count has to come
    /// from somewhere other than the container's duration.
    func testTheStreamReportsARealFrameCount() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.m2v is missing")
        }
        guard let decoder = MPEGStreamDecoder(url: url) else {
            return XCTFail("the fixture did not open")
        }
        XCTAssertGreaterThan(
            decoder.frameCount, 100,
            "a six-second clip is about 180 frames; a count of 1 means every index "
                + "maps to frame 0 and the clip never appears to move")
    }
}

extension MPEGCorruptorTests {
    /// What the fixture is actually made of, so the mode tests are grounded.
    func testTheFixtureContainsPredictedPictures() throws {
        let bytes = try streamBytes()
        let pictures = MPEGFormat.pictures(in: bytes)
        let counts = Dictionary(grouping: pictures, by: \.type).mapValues(\.count)
        print("[diagnostic] picture types: \(counts.mapValues { $0 })")
        XCTAssertGreaterThan(counts[.intra] ?? 0, 0)
        XCTAssertGreaterThan(
            (counts[.predicted] ?? 0) + (counts[.bidirectional] ?? 0), 0,
            "without predicted pictures there is nothing for the temporal modes to do")
    }

    /// Dropping frames must change which picture a given output index lands on.
    func testFrameDropShiftsWhichFrameYouGet() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.m2v is missing")
        }
        guard let decoder = MPEGStreamDecoder(url: url) else {
            return XCTFail("did not open")
        }
        let index = min(60, decoder.frameCount - 1)
        guard let clean = decoder.image(at: index, corruption: .inert) else {
            return XCTFail("no clean frame")
        }
        var dropping = CorruptionSettings(amount: 0.9, seed: 3)
        dropping.modePosition = MPEGCorruptionMode.frameDrop.normalisedPosition
        guard let dropped = decoder.image(at: index, corruption: dropping) else {
            return XCTFail("no dropped frame")
        }
        XCTAssertNotEqual(
            clean.pixels, dropped.pixels,
            "with pictures removed, output \(index) should come from later in the clip")
    }
}
