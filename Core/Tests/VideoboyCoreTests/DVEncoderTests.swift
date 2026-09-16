//
//  DVEncoderTests.swift — the DV re-encode round trip, and whether it is fast enough.
//
//  Purpose : Re-encoding a mixed bus to DV so it can be corrupted is only worth
//            having if it holds frame rate. This measures that before anything is
//            built on top of it, and pins the round trip's correctness.
//  Inputs   : synthetic patterns.
//  Outputs  : assertions, a timing note, and PNGs under selfqa/out/phase-5/.
//  Connects : DVEncoder, DIFCorruptor, DVDecoder.
//

import XCTest
@testable import VideoboyCore

final class DVEncoderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testEncoderProducesAWholeDVFrame() throws {
        let encoder = try DVEncoder(standard: .ntsc)
        let bars = TestPattern.colorBars()
        let bytes = try XCTUnwrap(encoder.encode(image: bars))

        // An NTSC DV frame is exactly 120000 bytes — 10 sequences of 150 80-byte
        // DIF blocks. Anything else is not a DV frame and the corruptor would refuse it.
        XCTAssertEqual(bytes.count, DVStandard.ntsc.frameBytes)
        XCTAssertEqual(bytes.count, 120_000)
    }

    func testEncodedFrameHasTheExpectedDIFStructure() throws {
        let encoder = try DVEncoder(standard: .ntsc)
        let bytes = try XCTUnwrap(encoder.encode(image: TestPattern.colorBars()))

        // The corruptor's layout model must hold for an encoded frame exactly as it
        // does for one off disk, or damaging a re-encoded bus would hit the wrong bytes.
        for offset in DVFormat.videoBlockOffsets(standard: .ntsc) {
            XCTAssertEqual(
                DVFormat.sectionType(of: bytes, atOffset: offset), .video,
                "offset \(offset) should be a video block in an encoded frame")
        }
    }

    func testRoundTripSurvivesRecognisably() throws {
        let encoder = try DVEncoder(standard: .ntsc)
        let decoder = try DVDecoder()
        let source = TestPattern.colorBars()

        let bytes = try XCTUnwrap(encoder.encode(image: source))
        let decoded = try XCTUnwrap(decoder.decode(frameBytes: bytes))

        XCTAssertEqual(decoded.width, 720)
        XCTAssertEqual(decoded.height, 480)
        // DV is lossy and 4:1:1, so this will not be exact — but the bars must still
        // be bars, or the interchange path is destroying the picture rather than
        // carrying it.
        let bars = FrameAssertions.looksLikeColorBars(decoded, tolerance: 40)
        XCTAssertTrue(bars.passed, bars.detail)
    }

    func testCorruptingAReEncodedFrameWorksTheSameAsAFileFrame() throws {
        let encoder = try DVEncoder(standard: .ntsc)
        let decoder = try DVDecoder()
        let check = SelfQACheck(name: "phase-5/bus-interchange")

        // The content matters here, and colour bars are the wrong choice: they are
        // uniform down every column, so swapping horizontal DIF sequences produces an
        // identical picture, and they are flat enough that most DCT coefficients are
        // zero, so flipping bits in them does almost nothing. Neither is a fault in
        // the corruptor — it is the test pattern being unrepresentative of a mix.
        // Real footage, decoded and re-encoded, is the honest stand-in.
        let sourceURL = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("samples/motion.dv is missing — run scripts/make-fixtures.sh")
        }
        let reader = try DVReader(url: sourceURL)
        let sourceDecoder = try DVDecoder()
        let mixed = try XCTUnwrap(sourceDecoder.decode(
            frameBytes: try XCTUnwrap(reader.frame(at: 40))))
        // A genuinely different earlier frame, so `holdSequences` has something to hold.
        let earlier = try XCTUnwrap(sourceDecoder.decode(
            frameBytes: try XCTUnwrap(reader.frame(at: 10))))

        let clean = try XCTUnwrap(encoder.encode(image: mixed))
        let previous = try XCTUnwrap(encoder.encode(image: earlier))
        let cleanDecoded = try XCTUnwrap(decoder.decode(frameBytes: clean))
        try check.writeImage(cleanDecoded, named: "00-encoded-decoded.png")
        check.note("decoded footage re-encoded to DV, standing in for a mixed bus")

        for (index, mode) in CorruptionMode.allCases.enumerated() {
            let corrupted = DIFCorruptor.corrupt(
                frame: clean,
                settings: CorruptionSettings(mode: mode, amount: 0.7, seed: 99),
                previousFrame: previous
            )
            XCTAssertEqual(corrupted.count, clean.count, "\(mode.rawValue) changed the frame length")

            guard let image = decoder.decode(frameBytes: corrupted) else {
                check.record(AssertionResult(
                    name: "\(mode.rawValue) decodes", passed: false, detail: "no picture"))
                continue
            }
            try check.writeImage(image, named: String(format: "%02d-%@.png", index + 1, mode.rawValue))
            check.record(FrameAssertions.framesDiffer(
                cleanDecoded, image, minimumFraction: 0.02,
                name: "\(mode.rawValue) damages the re-encoded mix"))
        }

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-5/bus-interchange/result.txt")
    }

    /// The question that decides whether this feature is worth having at all.
    func testRoundTripIsFastEnoughForLivePlayback() throws {
        let encoder = try DVEncoder(standard: .ntsc)
        let decoder = try DVDecoder()
        let source = TestPattern.colorBars()

        // Warm up: the first encode allocates and the first decode builds its scaler,
        // neither of which happens again.
        _ = encoder.encode(image: source).flatMap { decoder.decode(frameBytes: $0) }

        let iterations = 30
        let started = Date()
        for _ in 0..<iterations {
            guard let bytes = encoder.encode(image: source) else { continue }
            let corrupted = DIFCorruptor.corrupt(
                frame: bytes,
                settings: CorruptionSettings(mode: .shuffleBlocks, amount: 0.5, seed: 1)
            )
            _ = decoder.decode(frameBytes: corrupted)
        }
        let elapsed = Date().timeIntervalSince(started)
        let perFrame = elapsed / Double(iterations)
        let frameBudget = 1.0 / StandardDefinition.frameRate

        Log.echoesToStandardError = true
        Log.info(.dv, String(
            format: "DV interchange round trip: %.2f ms per frame (budget %.2f ms at %.2f fps)",
            perFrame * 1000, frameBudget * 1000, StandardDefinition.frameRate))
        Log.echoesToStandardError = false

        // It has to fit inside a frame with room left for the rest of the graph —
        // decode, composite, the analog chain and the present. A third of the budget
        // is the most this one stage can reasonably take.
        XCTAssertLessThan(
            perFrame, frameBudget / 3.0,
            String(format: "the round trip costs %.2f ms; a third of the %.2f ms frame budget is %.2f ms",
                   perFrame * 1000, frameBudget * 1000, frameBudget * 1000 / 3)
        )
    }
}

// MARK: - Data effect families

extension DVEncoderTests {

    func testFamilyIsIdentifiedFromTheFile() {
        func family(_ name: String) -> DataEffectFamily {
            DataEffectFamily.forMediaFile(at: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(family("clip.dv"), .dv)
        XCTAssertEqual(family("CLIP.DV"), .dv, "the extension check must be case-insensitive")
        XCTAssertEqual(family("clip.m2v"), .mpeg)
        XCTAssertEqual(family("clip.mpg"), .mpeg)
        // A still has no bitstream to corrupt, so it must offer nothing.
        XCTAssertEqual(family("still.png"), .none)
        XCTAssertEqual(family("photo.jpg"), .none)
        // A .mov can hold anything, so promising MPEG effects would be a guess.
        XCTAssertEqual(family("clip.mov"), .none)
        XCTAssertEqual(family("noextension"), .none)
    }

    func testOnlyImplementedFamiliesClaimToBeBuilt() {
        XCTAssertTrue(DataEffectFamily.dv.isImplemented)
        XCTAssertTrue(DataEffectFamily.mpeg.isImplemented)
        // None offers nothing, so there is nothing to be unimplemented.
        XCTAssertTrue(DataEffectFamily.none.effects.isEmpty)
    }

    func testDVFamilyOffersEveryCorruptionMode() {
        let effects = DataEffectFamily.dv.effects
        XCTAssertEqual(effects.count, CorruptionMode.allCases.count)
        XCTAssertTrue(effects.allSatisfy(\.isImplemented))
        XCTAssertTrue(effects.allSatisfy { !$0.displayName.isEmpty })
        // Identifiers must round-trip to a real mode, since that is how the UI's
        // selection reaches the corruptor.
        for effect in effects {
            XCTAssertNotNil(CorruptionMode(rawValue: effect.identifier))
        }
    }

    func testMPEGFamilyOffersEveryCorruptionMode() {
        let effects = DataEffectFamily.mpeg.effects
        XCTAssertEqual(effects.count, MPEGCorruptionMode.allCases.count)
        XCTAssertTrue(effects.allSatisfy(\.isImplemented))
        XCTAssertTrue(effects.allSatisfy { !$0.displayName.isEmpty })
        // Identifiers must round-trip to a real mode, since that is how the UI's
        // selection reaches the corruptor.
        for effect in effects {
            XCTAssertNotNil(MPEGCorruptionMode(rawValue: effect.identifier))
        }
    }

    func testAnEmptySourceOffersNoDataEffects() {
        // An empty channel must not advertise effects it cannot apply.
        let node = ClipSourceNode(identifier: "test", context: nil)
        XCTAssertEqual(node.dataEffectFamily, .none)
    }

    func testBusInterchangeDecidesTheBusFamily() {
        let node = BusCodecNode(identifier: "bus", context: nil)
        // No interchange, no bitstream, no data effects.
        XCTAssertEqual(node.interchange, .none)
        XCTAssertEqual(node.dataEffectFamily, .none)

        node.interchange = .dv
        XCTAssertEqual(node.dataEffectFamily, .dv)
        XCTAssertEqual(InterchangeCodec.dv.family, .dv)
        XCTAssertEqual(InterchangeCodec.none.family, .none)
    }

    func testBusCodecIsAPassThroughWhenIdle() {
        // With no interchange or no damage it must not read back, encode or decode —
        // that would be the most expensive no-op in the graph.
        let node = BusCodecNode(identifier: "bus", context: nil)
        node.interchange = .none
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        // With a nil Metal context it can only pass through; the assertion is that it
        // does so without trapping.
        XCTAssertNil(node.render(inputs: [], context: context))
    }
}
