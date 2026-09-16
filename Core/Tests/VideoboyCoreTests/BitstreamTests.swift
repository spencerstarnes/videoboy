//
//  BitstreamTests.swift — the wedge, proven on real DV bytes.
//
//  Purpose : These are the most important tests in the project. They establish that
//            the corruptor damages compressed DV *before* decode, that the result
//            still decodes, that it is deterministic given a seed, and that it does
//            not destroy the frame structure.
//  Inputs  : samples/*.dv — genuine DV bitstreams.
//  Outputs : assertions, plus decoded PNGs under selfqa/out/phase-1/ so the datamosh
//            can actually be looked at.
//  Connects: DVReader, DIFCorruptor, DVDecoder, DVFormat.
//  Extend  : a new corruption mode needs a case in `testEveryModePreservesStructure`
//            and, if it has a distinctive visual signature, its own decoded PNG.
//

import XCTest
@testable import VideoboyCore

final class BitstreamTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// The DV fixture every test in here works from.
    private func openFixture(_ name: String = "bars.dv") throws -> DVReader {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/\(name) is missing — run scripts/make-fixtures.sh")
        }
        return try DVReader(url: url)
    }

    // MARK: - Framing

    func testReaderIdentifiesNTSCFramingFromFileSize() throws {
        let reader = try openFixture()
        XCTAssertEqual(reader.standard, .ntsc)
        XCTAssertGreaterThan(reader.frameCount, 0)
        // A DV frame is a fixed size; this is what makes raw DV seekable by arithmetic.
        XCTAssertEqual(DVStandard.ntsc.frameBytes, 120_000)
        let frame = try XCTUnwrap(reader.frame(at: 0))
        XCTAssertEqual(frame.count, DVStandard.ntsc.frameBytes)
    }

    func testVideoBlockOffsetsMatchTheActualBitstream() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 0))
        let offsets = DVFormat.videoBlockOffsets(standard: .ntsc)

        // 10 sequences x 135 video blocks.
        XCTAssertEqual(offsets.count, 1350)

        // Every offset the layout model predicts must really be a video block in the
        // file. If this fails, the corruptor is damaging the wrong bytes.
        for offset in offsets {
            XCTAssertEqual(
                DVFormat.sectionType(of: frame, atOffset: offset), .video,
                "offset \(offset) was predicted to be a video block but is not"
            )
        }
    }

    func testReaderWrapsIndicesForLooping() throws {
        let reader = try openFixture()
        XCTAssertEqual(reader.wrappedIndex(0), 0)
        XCTAssertEqual(reader.wrappedIndex(reader.frameCount), 0)
        XCTAssertEqual(reader.wrappedIndex(reader.frameCount + 3), 3)
        // Scrubbing backwards past the start must wrap forward, not go negative.
        XCTAssertEqual(reader.wrappedIndex(-1), reader.frameCount - 1)
    }

    // MARK: - Corruptor invariants

    func testCorruptionIsDeterministicForAGivenSeed() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 5))

        for mode in CorruptionMode.allCases {
            let settings = CorruptionSettings(mode: mode, amount: 0.6, seed: 12345)
            let first = DIFCorruptor.corrupt(frame: frame, settings: settings, previousFrame: frame)
            let second = DIFCorruptor.corrupt(frame: frame, settings: settings, previousFrame: frame)
            XCTAssertEqual(first, second, "\(mode.rawValue) must be deterministic for a fixed seed")
        }
    }

    func testDifferentSeedsGiveDifferentDamage() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 5))
        let a = DIFCorruptor.corrupt(
            frame: frame, settings: CorruptionSettings(mode: .dropBlocks, amount: 0.6, seed: 1))
        let b = DIFCorruptor.corrupt(
            frame: frame, settings: CorruptionSettings(mode: .dropBlocks, amount: 0.6, seed: 2))
        XCTAssertNotEqual(a, b, "re-rolling the seed must change the damage")
    }

    func testZeroAmountIsExactlyAPassThrough() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 5))
        for mode in CorruptionMode.allCases {
            let untouched = DIFCorruptor.corrupt(
                frame: frame, settings: CorruptionSettings(mode: mode, amount: 0, seed: 7))
            XCTAssertEqual(untouched, frame, "\(mode.rawValue) at amount 0 must not alter a single byte")
        }
    }

    func testEveryModePreservesStructure() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 5))
        let previous = try XCTUnwrap(reader.frame(at: 4))

        for mode in CorruptionMode.allCases {
            let settings = CorruptionSettings(mode: mode, amount: 0.8, seed: 99)
            let corrupted = DIFCorruptor.corrupt(
                frame: frame, settings: settings, previousFrame: previous)

            // Invariant 1: length is preserved, or every later frame desyncs.
            XCTAssertEqual(corrupted.count, frame.count, "\(mode.rawValue) changed the frame length")

            // Invariant 2: only video blocks are touched. Header, subcode and VAUX
            // blocks must be byte-identical, or decoders reject the frame outright.
            for sequence in 0..<DVStandard.ntsc.sequencesPerFrame {
                for block in 0..<6 {
                    let offset = DVFormat.blockOffset(sequence: sequence, block: block)
                    let range = offset..<(offset + DVFormat.blockBytes)
                    XCTAssertEqual(
                        Array(corrupted[range]), Array(frame[range]),
                        "\(mode.rawValue) damaged a non-picture block at sequence \(sequence) block \(block)"
                    )
                }
            }

            // Invariant 3: every video block keeps its own 3-byte header, so the
            // decoder still knows which macroblock the (wrong) data belongs to.
            for offset in DVFormat.videoBlockOffsets(standard: .ntsc) {
                XCTAssertEqual(
                    DVFormat.sectionType(of: corrupted, atOffset: offset), .video,
                    "\(mode.rawValue) destroyed a video block header at \(offset)"
                )
            }
        }
    }

    func testCorruptionActuallyChangesBytes() throws {
        // motion.dv, not bars.dv: `holdSequences` replaces this frame's blocks with
        // the previous frame's, which is correctly a no-op on a static picture where
        // consecutive frames are byte-identical. Only moving content tests it.
        let reader = try openFixture("motion.dv")
        let frame = try XCTUnwrap(reader.frame(at: 5))
        let previous = try XCTUnwrap(reader.frame(at: 4))

        for mode in CorruptionMode.allCases {
            let corrupted = DIFCorruptor.corrupt(
                frame: frame,
                settings: CorruptionSettings(mode: mode, amount: 0.9, seed: 4242),
                previousFrame: previous
            )
            let changedBytes = zip(frame, corrupted).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            XCTAssertGreaterThan(changedBytes, 0, "\(mode.rawValue) at amount 0.9 changed nothing")
        }
    }

    func testAmountScalesTheDamage() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 5))

        func changedByteCount(amount: Double) -> Int {
            let corrupted = DIFCorruptor.corrupt(
                frame: frame, settings: CorruptionSettings(mode: .dropBlocks, amount: amount, seed: 8))
            return zip(frame, corrupted).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        }

        let light = changedByteCount(amount: 0.2)
        let heavy = changedByteCount(amount: 0.9)
        XCTAssertGreaterThan(heavy, light, "a higher amount must damage more of the frame")
    }

    func testModeSelectionFromANormalisedParameter() {
        // The FX panel drives mode with a 0...1 slider (param code 32B), so the ends
        // of the slider must land exactly on the first and last modes.
        XCTAssertEqual(CorruptionMode.from(normalised: 0), CorruptionMode.allCases.first)
        XCTAssertEqual(CorruptionMode.from(normalised: 1), CorruptionMode.allCases.last)
        // Out-of-range values clamp rather than trap.
        XCTAssertEqual(CorruptionMode.from(normalised: -5), CorruptionMode.allCases.first)
        XCTAssertEqual(CorruptionMode.from(normalised: 5), CorruptionMode.allCases.last)
    }

    func testMalformedFrameIsPassedThroughNotDropped() {
        // A short buffer must never crash or vanish: playback continues, logged.
        let short: [UInt8] = Array(repeating: 0xAB, count: 1000)
        let result = DIFCorruptor.corrupt(
            frame: short, settings: CorruptionSettings(mode: .dropBlocks, amount: 1.0, seed: 1))
        XCTAssertEqual(result, short)
    }

    // MARK: - Decode

    func testCleanDVFrameDecodesToAPicture() throws {
        let reader = try openFixture()
        let decoder = try DVDecoder()
        let frame = try XCTUnwrap(reader.frame(at: 10))

        let image = try XCTUnwrap(decoder.decode(frameBytes: frame), "a clean DV frame must decode")
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 480)
        XCTAssertTrue(FrameAssertions.signalPresent(image), "a decoded DV frame must carry picture")

        // bars.dv is SMPTE bars, so the decoded frame must actually look like them.
        // This is the end-to-end proof that the decode path is wired up correctly:
        // wrong colour order or a wrong pixel format would fail here.
        let bars = FrameAssertions.looksLikeColorBars(image, tolerance: 40)
        XCTAssertTrue(bars.passed, bars.detail)
    }

    /// The headline test: corrupt the compressed bytes, then decode them, and confirm
    /// the decoder produced a *different but still valid* picture.
    func testCorruptedDVStillDecodesAndLooksDifferent() throws {
        let reader = try openFixture("motion.dv")
        let decoder = try DVDecoder()
        let check = SelfQACheck(name: "phase-1/dv-corruption")

        let frameIndex = 30
        let clean = try XCTUnwrap(reader.frame(at: frameIndex))
        let previous = try XCTUnwrap(reader.frame(at: frameIndex - 1))

        let cleanImage = try XCTUnwrap(decoder.decode(frameBytes: clean))
        try check.writeImage(cleanImage, named: "00-clean.png")
        check.note("source: motion.dv frame \(frameIndex), \(reader.frameCount) frames total")
        check.record(FrameAssertions.hasDimensions(cleanImage, width: 720, height: 480))
        check.record(FrameAssertions.hasSignal(cleanImage))

        for (index, mode) in CorruptionMode.allCases.enumerated() {
            let settings = CorruptionSettings(mode: mode, amount: 0.7, seed: 1234)
            let corruptedBytes = DIFCorruptor.corrupt(
                frame: clean, settings: settings, previousFrame: previous)

            // The bytes must genuinely differ before decode; otherwise a "different
            // picture" below would prove nothing about the bitstream path.
            XCTAssertNotEqual(corruptedBytes, clean, "\(mode.rawValue) left the bitstream untouched")

            guard let corruptedImage = decoder.decode(frameBytes: corruptedBytes) else {
                check.record(AssertionResult(
                    name: "\(mode.rawValue) decodes", passed: false,
                    detail: "the decoder produced no picture from corrupted bytes"
                ))
                continue
            }
            try check.writeImage(corruptedImage, named: String(format: "%02d-%@.png", index + 1, mode.rawValue))

            // Still a valid, full-size picture...
            check.record(AssertionResult(
                name: "\(mode.rawValue) decodes to full size",
                passed: corruptedImage.width == 720 && corruptedImage.height == 480,
                detail: "got \(corruptedImage.width)x\(corruptedImage.height)"
            ))
            // ...but a visibly different one. This is the wedge working.
            check.record(FrameAssertions.framesDiffer(
                cleanImage, corruptedImage,
                minimumFraction: 0.02,
                name: "\(mode.rawValue) changes the picture"
            ))
        }

        check.note("decoder saw \(decoder.damagedFrameCount) damaged frames of \(decoder.decodedFrameCount) decoded")
        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-1/dv-corruption/result.txt")
    }

    func testHoldSequencesPullsPixelsFromThePreviousFrame() throws {
        let reader = try openFixture("motion.dv")
        let decoder = try DVDecoder()

        // motion.dv moves, so frames 40 and 41 are genuinely different pictures.
        let previous = try XCTUnwrap(reader.frame(at: 40))
        let current = try XCTUnwrap(reader.frame(at: 41))

        // Holding every sequence should reproduce the previous frame's picture.
        let held = DIFCorruptor.corrupt(
            frame: current,
            settings: CorruptionSettings(mode: .holdSequences, amount: 1.0, seed: 3),
            previousFrame: previous
        )
        let previousImage = try XCTUnwrap(decoder.decode(frameBytes: previous))
        let currentImage = try XCTUnwrap(decoder.decode(frameBytes: current))
        let heldImage = try XCTUnwrap(decoder.decode(frameBytes: held))

        let differenceFromPrevious = FrameAssertions.differingPixelFraction(heldImage, previousImage)
        let differenceFromCurrent = FrameAssertions.differingPixelFraction(heldImage, currentImage)
        XCTAssertLessThan(
            differenceFromPrevious, differenceFromCurrent,
            "a fully held frame must resemble the previous frame more than the current one"
        )
    }

    func testHoldWithNoPreviousFrameIsAPassThrough() throws {
        let reader = try openFixture()
        let frame = try XCTUnwrap(reader.frame(at: 0))
        // The first frame of a clip has nothing to hold, which must be a no-op.
        let result = DIFCorruptor.corrupt(
            frame: frame,
            settings: CorruptionSettings(mode: .holdSequences, amount: 1.0, seed: 1),
            previousFrame: nil
        )
        XCTAssertEqual(result, frame)
    }
}
