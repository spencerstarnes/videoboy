//
//  DatamoshTests.swift — the live H.264 datamosh, rule by rule and end to end.
//
//  The syntax and engine tests run on hand-built H.264 headers (a tiny bit writer
//  below), so each rule — drop the keyframe, renumber the P-frame, replay the loop —
//  is pinned without a codec. The end-to-end test runs the real thing: VideoToolbox
//  encodes two genuinely different clips, the engine moshes the cut, libav decodes,
//  and the PNGs land in selfqa/out/mosh/ as evidence.
//

import XCTest
import Metal
@testable import VideoboyCore

/// Writes MSB-first bits and Exp-Golomb codes, to build test headers.
private struct BitWriter {
    var bytes: [UInt8] = []
    var count = 0

    mutating func bit(_ value: UInt32) {
        if count % 8 == 0 { bytes.append(0) }
        if value & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(count % 8) }
        count += 1
    }
    mutating func bits(_ value: UInt32, _ width: Int) {
        for index in stride(from: width - 1, through: 0, by: -1) { bit((value >> UInt32(index)) & 1) }
    }
    mutating func ue(_ value: UInt32) {
        let coded = value + 1
        let width = 32 - coded.leadingZeroBitCount
        bits(0, width - 1)
        bits(coded, width)
    }
    /// rbsp_trailing_bits, then payload bytes to stand in for slice data.
    mutating func finish(payload: [UInt8] = []) -> [UInt8] {
        bit(1)
        while count % 8 != 0 { bit(0) }
        return bytes + payload
    }
}

private enum Fixture {
    /// Main-profile SPS: 4-bit frame_num, POC type 0 with a 6-bit LSB.
    static let sps: [UInt8] = {
        var writer = BitWriter()
        writer.bits(77, 8); writer.bits(0, 8); writer.bits(30, 8)
        writer.ue(0)            // sps id
        writer.ue(0)            // log2_max_frame_num_minus4 → 4 bits
        writer.ue(0)            // poc type 0
        writer.ue(2)            // log2_max_poc_lsb_minus4 → 6 bits
        writer.ue(1)            // max_num_ref_frames
        writer.bit(0)           // gaps
        writer.ue(44); writer.ue(29)
        writer.bit(1)           // frame_mbs_only
        return [0x67] + H264EmulationPrevention.escape(writer.finish())
    }()

    static let pps: [UInt8] = {
        var writer = BitWriter()
        writer.ue(0); writer.ue(0); writer.bit(0); writer.bit(0)
        return [0x68] + H264EmulationPrevention.escape(writer.finish())
    }()

    /// A slice. `payload` distinguishes one picture from another in assertions.
    static func slice(idr: Bool, frameNum: UInt32, poc: UInt32, payload: UInt8, size: Int = 40) -> [UInt8] {
        var writer = BitWriter()
        writer.ue(0)                       // first_mb_in_slice
        writer.ue(idr ? 7 : 5)             // slice_type I / P
        writer.ue(0)                       // pps id
        writer.bits(frameNum, 4)
        if idr { writer.ue(0) }            // idr_pic_id
        writer.bits(poc, 6)
        let rbsp = writer.finish(payload: [UInt8](repeating: payload, count: size))
        return [idr ? 0x65 : 0x41] + H264EmulationPrevention.escape(rbsp)
    }

    static func keyframe(payload: UInt8 = 0xAA) -> H264AccessUnit {
        H264AccessUnit(nalUnits: [sps, pps, slice(idr: true, frameNum: 0, poc: 0, payload: payload)],
                       isKeyframe: true)
    }

    static func pFrame(_ number: UInt32, payload: UInt8, size: Int = 40) -> H264AccessUnit {
        H264AccessUnit(nalUnits: [slice(idr: false, frameNum: number % 16, poc: (number * 2) % 64,
                                        payload: payload, size: size)],
                       isKeyframe: false)
    }

    /// (frame_num, POC LSB, first payload byte) of every slice in `units`.
    static func describe(_ units: [H264AccessUnit]) throws -> [(UInt32, UInt32, UInt8)] {
        var sps: [UInt32: H264SPS] = [:]
        var pps: [UInt32: H264PPS] = [:]
        let parsedSPS = try H264SPS.parse(Fixture.sps)
        sps[parsedSPS.id] = parsedSPS
        let parsedPPS = try H264PPS.parse(Fixture.pps)
        pps[parsedPPS.id] = parsedPPS
        var result: [(UInt32, UInt32, UInt8)] = []
        for unit in units {
            for nal in unit.nalUnits where H264NALType(header: nal[0]).isSlice {
                let (header, rbsp) = try H264SliceHeader.parse(nal, sps: sps, pps: pps)
                var reader = H264BitReader(rbsp)
                _ = try reader.bits(header.pocLSBBitOffset!)
                let poc = try reader.bits(header.pocLSBBits)
                result.append((header.frameNum, poc, rbsp.last!))
            }
        }
        return result
    }
}

final class H264SyntaxTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testEmulationPreventionRoundTrips() {
        let rbsp: [UInt8] = [0, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 9]
        let escaped = H264EmulationPrevention.escape(rbsp)
        XCTAssertEqual(escaped, [0, 0, 3, 0, 1, 0, 0, 3, 2, 0, 0, 3, 3, 0, 0, 4, 9])
        XCTAssertEqual(H264EmulationPrevention.unescape(escaped[...]), rbsp)
    }

    func testExpGolombReadsWhatWasWritten() throws {
        var writer = BitWriter()
        for value: UInt32 in [0, 1, 2, 7, 255, 1000] { writer.ue(value) }
        var reader = H264BitReader(writer.finish())
        for value: UInt32 in [0, 1, 2, 7, 255, 1000] { XCTAssertEqual(try reader.ue(), value) }
    }

    func testTheSPSFieldsARenumberingNeedsAreRead() throws {
        let sps = try H264SPS.parse(Fixture.sps)
        XCTAssertEqual(sps.log2MaxFrameNum, 4)
        XCTAssertEqual(sps.pictureOrderCountType, 0)
        XCTAssertEqual(sps.log2MaxPictureOrderCountLSB, 6)
        XCTAssertTrue(sps.frameMBsOnly)
    }

    func testRenumberingChangesOnlyTheNumbers() throws {
        let sps = try H264SPS.parse(Fixture.sps)
        let pps = try H264PPS.parse(Fixture.pps)
        let slice = Fixture.slice(idr: false, frameNum: 3, poc: 6, payload: 0x5A)
        let (header, rbsp) = try H264SliceHeader.parse(slice, sps: [0: sps], pps: [0: pps])
        XCTAssertEqual(header.frameNum, 3)

        let renumbered = header.renumbered(rbsp: rbsp, headerByte: slice[0], frameNum: 11, pocLSB: 22)
        let described = try Fixture.describe([H264AccessUnit(nalUnits: [renumbered], isKeyframe: false)])
        XCTAssertEqual(described.first?.0, 11)
        XCTAssertEqual(described.first?.1, 22)
        XCTAssertEqual(renumbered.count, slice.count, "same-width fields: the slice stays the same size")
        XCTAssertEqual(renumbered.suffix(30), slice.suffix(30), "slice data after the header is untouched")
    }

    func testAVCCIsSplitIntoNALUnits() {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x67, 0x01, 0, 0, 0, 3, 0x41, 0x02, 0x03]
        XCTAssertEqual(H264AccessUnit.nalUnits(fromAVCC: avcc), [[0x67, 0x01], [0x41, 0x02, 0x03]])
    }
}

final class MoshEngineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func run(_ engine: MoshEngine, _ units: [H264AccessUnit], _ controls: MoshControls) -> [H264AccessUnit] {
        units.flatMap { engine.process($0, controls: controls) }
    }

    func testCleanStreamPassesThroughInOrder() throws {
        let engine = MoshEngine()
        let out = run(engine, [Fixture.keyframe()] + (1...5).map { Fixture.pFrame($0, payload: UInt8($0)) },
                      MoshControls())
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(try Fixture.describe(out).map(\.0), [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(out[0].nalUnits.contains(Fixture.sps), "parameter sets go ahead of the first picture")
    }

    func testTheDecoderIsNeverStartedOnAPFrame() {
        let engine = MoshEngine()
        XCTAssertTrue(engine.process(Fixture.pFrame(1, payload: 1), controls: MoshControls()).isEmpty)
        XCTAssertFalse(engine.started)
        XCTAssertEqual(engine.process(Fixture.keyframe(), controls: MoshControls()).count, 1)
        XCTAssertTrue(engine.started)
    }

    func testMoshDropsTheKeyframeAndRenumbersWhatFollows() throws {
        let engine = MoshEngine()
        _ = run(engine, [Fixture.keyframe()] + (1...6).map { Fixture.pFrame($0, payload: 1) }, MoshControls())

        // A cut: the encoder sends a new keyframe, then the new scene's P-frames.
        let mosh = MoshControls(mosh: 0.3)
        let cut = run(engine, [Fixture.keyframe(payload: 0xBB)] + (1...3).map { Fixture.pFrame($0, payload: 0xB0) }, mosh)
        let described = try Fixture.describe(cut)
        XCTAssertFalse(described.contains { $0.2 == 0xBB }, "the new scene's keyframe never reaches the decoder")
        XCTAssertEqual(described.map(\.2), [0xB0, 0xB0, 0xB0], "its P-frames do — onto the old picture")
        XCTAssertEqual(described.map(\.0), [7, 8, 9], "numbered on from the old scene, so the decoder sees no gap")
        XCTAssertEqual(engine.statistics.droppedKeyframes, 1)
    }

    func testMoshDropsAFrameThatIsMostlyNewPicture() throws {
        let engine = MoshEngine()
        _ = run(engine, [Fixture.keyframe()] + (1...10).map { Fixture.pFrame($0, payload: 1, size: 40) }, MoshControls())
        let out = run(engine, [Fixture.pFrame(11, payload: 0xCC, size: 600), Fixture.pFrame(12, payload: 2)],
                      MoshControls(mosh: 0.5))
        XCTAssertEqual(try Fixture.describe(out).map(\.2), [2], "the intra-heavy cut frame is dropped")
        XCTAssertEqual(engine.statistics.droppedCuts, 1)
    }

    func testBloomReplaysRecentPFramesInALoop() throws {
        let engine = MoshEngine()
        _ = run(engine, [Fixture.keyframe()] + (1...4).map { Fixture.pFrame($0, payload: UInt8(0x10 + $0)) },
                MoshControls())
        let out = run(engine, (5...10).map { Fixture.pFrame($0, payload: 0xEE) }, MoshControls(bloomLength: 2))
        let described = try Fixture.describe(out)
        XCTAssertEqual(described.map(\.2), [0x13, 0x14, 0x13, 0x14, 0x13, 0x14],
                       "the last two P-frames, again and again; the live frames are held back")
        XCTAssertEqual(described.map(\.0), [5, 6, 7, 8, 9, 10], "each replay is a new picture to the decoder")
        XCTAssertEqual(described.map(\.1), [10, 12, 14, 16, 18, 20])
    }

    func testHealLetsTheKeyframeThroughEvenWhileMoshing() throws {
        let engine = MoshEngine()
        _ = run(engine, [Fixture.keyframe()] + (1...3).map { Fixture.pFrame($0, payload: 1) }, MoshControls())
        let out = run(engine, [Fixture.keyframe(payload: 0xDD)], MoshControls(mosh: 1, heal: true))
        XCTAssertEqual(try Fixture.describe(out).map(\.2), [0xDD])
        XCTAssertEqual(try Fixture.describe(out).map(\.0), [0], "an IDR restarts the numbering")
    }

    func testLoopFaderMapsToALoopLength() {
        XCTAssertEqual(MoshControls.bloomLength(fromNormalised: 0), 1)
        XCTAssertEqual(MoshControls.bloomLength(fromNormalised: DatamoshNode.defaultLoop), 4)
        XCTAssertEqual(MoshControls.bloomLength(fromNormalised: 1), 16)
    }

    func testHalfBloomAlternatesReplaysWithLiveFrames() throws {
        let engine = MoshEngine()
        _ = run(engine, [Fixture.keyframe()] + (1...4).map { Fixture.pFrame($0, payload: UInt8(0x10 + $0)) },
                MoshControls())
        let out = run(engine, (5...10).map { Fixture.pFrame($0, payload: UInt8(0x20 + $0)) },
                      MoshControls(bloom: 0.5, bloomLength: 2))
        XCTAssertEqual(try Fixture.describe(out).map(\.2), [0x25, 0x13, 0x27, 0x14, 0x29, 0x13],
                       "live, replay, live, replay: the stream slows rather than stops")
        XCTAssertEqual(engine.statistics.bloomed, 3)
    }

    func testBloomFadesOutAsTheFaderComesDown() throws {
        // The complaint that started this: pulling bloom down did nothing until 0.
        // Replays per 30 frames must fall steadily with the fader.
        var counts: [Int] = []
        for amount in [1.0, 0.75, 0.5, 0.25, 0.125] {
            let engine = MoshEngine()
            _ = run(engine, [Fixture.keyframe()] + (1...4).map { Fixture.pFrame($0, payload: 1) }, MoshControls())
            _ = run(engine, (5...34).map { Fixture.pFrame($0, payload: 2) }, MoshControls(bloom: amount, bloomLength: 4))
            counts.append(engine.statistics.bloomed)
        }
        XCTAssertEqual(counts, [30, 22, 15, 7, 3])
    }

    func testMeltDropsOrdinaryFramesAndMoshAloneDoesNot() throws {
        let moshOnly = MoshEngine()
        _ = run(moshOnly, [Fixture.keyframe()] + (1...200).map { Fixture.pFrame($0 % 16, payload: 1) }, MoshControls(mosh: 1))
        XCTAssertEqual(moshOnly.statistics.droppedRandom, 0, "mosh drops cuts; random drops are melt's job")

        let melting = MoshEngine()
        _ = run(melting, [Fixture.keyframe()] + (1...200).map { Fixture.pFrame($0 % 16, payload: 1) }, MoshControls(melt: 1))
        XCTAssertGreaterThan(melting.statistics.droppedRandom, 40)
        XCTAssertLessThan(melting.statistics.droppedRandom, 110)
        XCTAssertTrue(melting.started, "the starting keyframe is never melted away")
    }
}

/// The eased heal, heal on the beat, and the card's choice faders.
final class MoshHealTests: XCTestCase {

    func testAHealEasesInThenAsksForTheKeyframeAndDropsAwayWhenItLands() {
        var envelope = MoshHealEnvelope()
        XCTAssertEqual(envelope.trigger(frames: 4), .none)
        var actions: [MoshHealEnvelope.Action] = []
        var cleans: [Double] = []
        for _ in 0..<4 {
            actions.append(envelope.advance(frames: 4, neutral: false))
            cleans.append(envelope.clean)
        }
        XCTAssertEqual(cleans, [0.25, 0.5, 0.75, 1])
        XCTAssertEqual(actions, [.none, .none, .none, .requestKeyframe], "the keyframe only once the screen is clean")
        XCTAssertEqual(envelope.advance(frames: 4, neutral: false), .none)
        XCTAssertEqual(envelope.clean, 1, "held clean until the keyframe is on screen")
        envelope.keyframeShown()
        XCTAssertEqual(envelope.phase, .idle)
        XCTAssertEqual(envelope.clean, 0)
    }

    func testAnInstantHealIsTheOldBehaviour() {
        var envelope = MoshHealEnvelope()
        XCTAssertEqual(envelope.trigger(frames: 0), .requestKeyframe)
        XCTAssertEqual(envelope.advance(frames: 0, neutral: false), .none)
        XCTAssertEqual(envelope.clean, 0)
        XCTAssertEqual(envelope.advance(frames: 0, neutral: true), .stop, "letting go with no heal time stops at once")
    }

    func testALostKeyframeIsAskedForAgain() {
        var envelope = MoshHealEnvelope()
        _ = envelope.trigger(frames: 1)
        XCTAssertEqual(envelope.advance(frames: 1, neutral: false), .requestKeyframe)
        var again = 0
        for _ in 0...MoshHealEnvelope.keyframeTimeout where envelope.advance(frames: 1, neutral: false) == .requestKeyframe {
            again += 1
        }
        XCTAssertEqual(again, 1)
    }

    func testLettingGoFadesOutThenStopsAndPushingBackUpReturns() {
        var envelope = MoshHealEnvelope()
        XCTAssertEqual(envelope.advance(frames: 4, neutral: true), .none)
        XCTAssertEqual(envelope.advance(frames: 4, neutral: true), .none)
        XCTAssertEqual(envelope.clean, 0.5)
        // Pushed back up half way through the release: the mosh comes back, no jump.
        XCTAssertEqual(envelope.advance(frames: 4, neutral: false), .none)
        XCTAssertEqual(envelope.phase, .returning)
        XCTAssertEqual(envelope.clean, 0.25)
        _ = envelope.advance(frames: 4, neutral: false)
        XCTAssertEqual(envelope.phase, .idle)
        // Let go for good.
        let actions = (0..<4).map { _ in envelope.advance(frames: 4, neutral: true) }
        XCTAssertEqual(actions, [.none, .none, .none, .stop])
        XCTAssertEqual(envelope.clean, 0)
    }

    func testPressesDuringAHealAreIgnored() {
        var envelope = MoshHealEnvelope()
        _ = envelope.trigger(frames: 10)
        _ = envelope.advance(frames: 10, neutral: false)
        XCTAssertEqual(envelope.trigger(frames: 10), .none)
        XCTAssertEqual(envelope.phase, .healing)
        XCTAssertEqual(envelope.clean, 0.1, accuracy: 1e-9)
    }

    func testHealTimeFaderIsFramesUpToTwoSeconds() {
        XCTAssertEqual(MoshHealEnvelope.frames(fromNormalised: 0), 0)
        XCTAssertEqual(MoshHealEnvelope.frames(fromNormalised: DatamoshNode.defaultHealTime), 15)
        XCTAssertEqual(MoshHealEnvelope.frames(fromNormalised: 1), 60)
    }

    private func position(beats: Double, beatsPerBar: Int = 4) -> MusicalPosition {
        let whole = Int(beats.rounded(.down))
        return MusicalPosition(bar: whole / beatsPerBar, beat: whole % beatsPerBar,
                               phase: beats - Double(whole), totalBeats: beats)
    }

    func testTheBeatTriggerFiresOnEachBoundaryCrossed() {
        var trigger = MoshBeatTrigger()
        let frames = stride(from: 0.0, to: 4.0, by: 0.1).map { position(beats: $0) }
        let fired = frames.filter { trigger.fires(every: .beat, at: $0) }.map { Int($0.totalBeats.rounded(.down)) }
        XCTAssertEqual(fired, [1, 2, 3], "once per beat, not on the frame the transport started")
    }

    func testTheBeatTriggerCountsBarsAndStaysQuietWhenStopped() {
        var trigger = MoshBeatTrigger()
        var fired = 0
        for beats in stride(from: 0.0, to: 16.0, by: 0.25) where trigger.fires(every: .twoBars, at: position(beats: beats)) {
            fired += 1
        }
        XCTAssertEqual(fired, 1, "bars 0-3: one boundary, at bar 2")
        XCTAssertFalse(trigger.fires(every: .twoBars, at: nil))
        XCTAssertFalse(trigger.fires(every: .twoBars, at: position(beats: 40)), "no heal on the first frame after a restart")
        XCTAssertFalse(trigger.fires(every: .off, at: position(beats: 48)))
        XCTAssertFalse(trigger.fires(every: .beat, at: position(beats: 49)), "changing the division is not a beat")
    }

    func testATapBetweenTwoFramesIsStillAPress() {
        let registry = ParamRegistry()
        registry.register(slot: "fx", parameters: DatamoshNode(identifier: "fx", context: nil).parameters)
        registry.setValue(1, slot: "fx", code: .moshHeal)
        registry.setValue(0, slot: "fx", code: .moshHeal)   // released before any frame
        XCTAssertTrue(registry.consumePress(slot: "fx", code: .moshHeal))
        XCTAssertFalse(registry.consumePress(slot: "fx", code: .moshHeal), "once per press")
        registry.setValue(1, slot: "fx", code: .moshAmount)
        XCTAssertFalse(registry.consumePress(slot: "fx", code: .moshAmount), "levels are not latched")
    }

    func testChoiceFadersReachEveryChoice() {
        XCTAssertEqual(MoshHealEvery.from(normalised: 0), .off)
        XCTAssertEqual(MoshHealEvery.from(normalised: 1), .fourBars)
        XCTAssertEqual(MoshHealShape.from(normalised: 0), .fade)
        XCTAssertEqual(MoshHealShape.from(normalised: 1), .luma)
        XCTAssertEqual(DatamoshNode.blendMode(fromNormalised: 0), .normal)
        XCTAssertEqual(DatamoshNode.blendMode(fromNormalised: 1), .softLight)
        XCTAssertFalse(DatamoshNode.blendModes.contains(.key))
    }
}

/// The real pipeline: VideoToolbox H.264 → MoshEngine → libav.
final class DatamoshPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Frames of a clip, at the size of the first one.
    func frames(_ name: String, count: Int) throws -> [ImageBuffer] {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) is not in samples/") }
        guard let decoder = ClipDecoders.open(url) else { throw XCTSkip("\(name) would not open") }
        return (0..<count).compactMap { decoder.image(at: $0 % max(decoder.frameCount, 1), corruption: .inert) }
    }

    /// Encodes `images` in order, returning the access units once all are out.
    func encode(_ images: [ImageBuffer]) throws -> [H264AccessUnit] {
        var units: [H264AccessUnit] = []
        let lock = NSLock()
        let first = images[0]
        let encoder = try H264LiveEncoder(width: first.width, height: first.height) { unit in
            lock.withLock { units.append(unit) }
        }
        for image in images { encoder.encode(image) }
        encoder.invalidate()   // completes every pending frame first
        return lock.withLock { units }
    }

    private func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var total = 0
        for index in stride(from: 0, to: min(a.pixels.count, b.pixels.count), by: 4) {
            for channel in 0..<3 { total += abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) }
        }
        return Double(total) / Double(a.width * a.height * 3)
    }

    func testACutWhileMoshingPaintsTheNewMotionOntoTheOldPicture() throws {
        let bars = try frames("bars.dv", count: 15)
        let motion = try frames("motion.mov", count: 45)
        guard let size = bars.first, motion.first.map({ $0.width == size.width && $0.height == size.height }) == true else {
            throw XCTSkip("the two fixtures differ in size")
        }
        let units = try encode(bars + motion)
        XCTAssertEqual(units.count, 60, "one access unit per frame")
        XCTAssertTrue(units[0].isKeyframe)

        let output = RepoPaths.selfQAOutput.appendingPathComponent("mosh", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // Clean and moshed decodes of the same encoded stream.
        func decodeAll(_ controls: (Int) -> MoshControls) throws -> [ImageBuffer?] {
            let engine = MoshEngine()
            let decoder = try H264MoshDecoder()
            var shown: ImageBuffer?
            return units.enumerated().map { index, unit in
                for fed in engine.process(unit, controls: controls(index)) {
                    if let picture = decoder.decode(fed) { shown = picture }
                }
                return shown
            }
        }
        let clean = try decodeAll { _ in MoshControls() }
        // Mosh held from just before the cut at frame 15.
        let moshed = try decodeAll { $0 >= 12 ? MoshControls(mosh: 0.4) : MoshControls() }

        for index in [14, 16, 20, 30, 44, 59] {
            if let picture = moshed[index] { try picture.writePNG(to: output.appendingPathComponent("moshed-\(index).png")) }
            if let picture = clean[index] { try picture.writePNG(to: output.appendingPathComponent("clean-\(index).png")) }
        }

        try motion[29].writePNG(to: output.appendingPathComponent("source-motion-29.png"))
        let late = 44
        let cleanLate = try XCTUnwrap(clean[late])
        let moshedLate = try XCTUnwrap(moshed[late])
        let fromMotion = meanDifference(moshedLate, motion[late - 15])
        let cleanFromMotion = meanDifference(cleanLate, motion[late - 15])
        let fromBars = meanDifference(moshedLate, bars.last!)

        XCTAssertLessThan(cleanFromMotion, 4, "clean: the round trip shows the new clip (diff \(cleanFromMotion))")
        XCTAssertGreaterThan(fromMotion, cleanFromMotion * 2,
                             "moshed: NOT the new clip — its motion is on the old picture (\(fromMotion) vs \(cleanFromMotion))")
        XCTAssertGreaterThan(fromBars, 1, "and not simply the old picture frozen either (\(fromBars))")
    }
}

extension DatamoshPipelineTests {

    /// Bloom: the last few P-frames replayed, so the same motion keeps pushing the
    /// picture while the live frames are held back.
    func testBloomKeepsApplyingTheSameMotion() throws {
        let motion = try frames("motion.mov", count: 60)
        let units = try encode(motion)
        let engine = MoshEngine()
        let decoder = try H264MoshDecoder()
        let output = RepoPaths.selfQAOutput.appendingPathComponent("mosh", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var pictures: [Int: ImageBuffer] = [:]
        for (index, unit) in units.enumerated() {
            let controls = index >= 20 ? MoshControls(bloomLength: 3) : MoshControls()
            for fed in engine.process(unit, controls: controls) {
                if let picture = decoder.decode(fed) { pictures[index] = picture }
            }
        }
        for index in [19, 25, 35, 59] {
            try pictures[index]?.writePNG(to: output.appendingPathComponent("bloom-\(index).png"))
        }
        XCTAssertEqual(engine.statistics.bloomed, 40, "every frame from 20 on is a replay")

        let start = try XCTUnwrap(pictures[19])
        let late = try XCTUnwrap(pictures[59])
        var total = 0
        for index in stride(from: 0, to: start.pixels.count, by: 4) {
            total += abs(Int(start.pixels[index]) - Int(late.pixels[index]))
        }
        let drift = Double(total) / Double(start.width * start.height)
        XCTAssertGreaterThan(drift, 2, "the replayed motion kept moving the picture (drift \(drift))")
    }
}

/// The node as the engine drives it: one render per frame on the main thread, with
/// the encoder and decoder running asynchronously for real.
final class DatamoshNodeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func clip(_ name: String, count: Int) throws -> [ImageBuffer] {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) is not in samples/") }
        guard let decoder = ClipDecoders.open(url) else { throw XCTSkip("\(name) would not open") }
        return (0..<count).compactMap { decoder.image(at: $0 % max(decoder.frameCount, 1), corruption: .inert) }
    }

    func testANeutralNodeReturnsItsInputAndHoldsNoEncoder() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal") }
        let node = DatamoshNode(identifier: "test.mosh", context: metal)
        let uploader = TextureUploader(context: metal, label: "test")
        let input = try XCTUnwrap(uploader.upload(ImageBuffer(width: 64, height: 48)))
        let output = node.render(inputs: [input], context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil))
        XCTAssertTrue(output === input, "neutral: the very same texture, no pass at all")
        XCTAssertFalse(node.isRunning)
    }

    func testTheNodeMoshesACutLiveWithoutEverWaitingOnTheTick() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal") }
        let bars = try clip("bars.dv", count: 20)
        let motion = try clip("motion.mov", count: 60)
        let node = DatamoshNode(identifier: "test.mosh", context: metal)
        let uploader = TextureUploader(context: metal, label: "test-input")
        let readback = try XCTUnwrap(OffscreenRenderer(context: metal))
        let output = RepoPaths.selfQAOutput.appendingPathComponent("mosh", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        node.mosh = 0.4
        var worstRender = 0.0
        var renderTimes: [Double] = []
        var lastPicture: ImageBuffer?
        let frames = bars + motion
        for (index, image) in frames.enumerated() {
            let input = try XCTUnwrap(uploader.upload(image))
            let started = Date()
            let rendered = node.render(inputs: [input], context: RenderContext(
                frameIndex: index, presentationTime: Double(index) / 29.97, musicalPosition: nil))
            let took = Date().timeIntervalSince(started)
            renderTimes.append(took)
            worstRender = max(worstRender, took)
            metal.waitForIdle()   // the engine's once-per-frame fence
            if let rendered, index == frames.count - 1 || index == 25 || index == 45 {
                lastPicture = readback.readback(rendered)
                try lastPicture?.writePNG(to: output.appendingPathComponent("node-\(index).png"))
            }
            // A frame's worth of time, so the asynchronous encode/decode can land.
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 29.97))
        }

        let sortedTimes = renderTimes.sorted()
        try "render ms: worst \(sortedTimes.last! * 1000), p95 \(sortedTimes[sortedTimes.count * 95 / 100] * 1000), median \(sortedTimes[sortedTimes.count / 2] * 1000)\nstatistics: \(node.statistics)\n"
            .write(to: output.appendingPathComponent("node-timing.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(node.isRunning)
        let statistics = node.statistics
        XCTAssertGreaterThan(statistics.emitted, 40, "frames flowed through the engine: \(statistics)")
        // "Never waits" asserted structurally (audit H5): a render that waited on the
        // GPU or the codec would cost about a frame, every frame. The median shows the
        // render path is short; the worst only has to stay under one frame. A tight
        // wall-clock worst inside `swift test` (a DEBUG build, sharing the machine)
        // flaked at 12–13 ms; worst-case timing belongs to release `stress`/`soak`.
        let median = sortedTimes[sortedTimes.count / 2]
        XCTAssertLessThan(median, 0.004,
                          "render never waits on the GPU or the codec (median \(median * 1000) ms)")
        XCTAssertLessThan(worstRender, 1 / 29.97,
                          "no render takes a whole frame (worst \(Int(worstRender * 1000)) ms)")
        let finalPicture = try XCTUnwrap(lastPicture)
        let source = motion[motion.count - 2]
        var total = 0
        for index in stride(from: 0, to: finalPicture.pixels.count, by: 4) {
            total += abs(Int(finalPicture.pixels[index]) - Int(source.pixels[index]))
        }
        let difference = Double(total) / Double(finalPicture.width * finalPicture.height)
        XCTAssertGreaterThan(difference, 8, "the output is moshed, not the clean input (diff \(difference))")

        // Letting go eases out over the heal time (15 frames by default), then the
        // input comes back untouched and the encoder is gone.
        node.mosh = 0
        let input = try XCTUnwrap(uploader.upload(motion[0]))
        var releaseFrames = 0
        var released: MTLTexture?
        repeat {
            released = node.render(inputs: [input], context: RenderContext(frameIndex: 999, presentationTime: 0, musicalPosition: nil))
            metal.waitForIdle()
            releaseFrames += 1
        } while node.isRunning && releaseFrames < 100
        XCTAssertEqual(releaseFrames, MoshHealEnvelope.frames(fromNormalised: DatamoshNode.defaultHealTime),
                       "released after the heal time, not at once")
        XCTAssertTrue(released === input)
        XCTAssertFalse(node.isRunning)
    }

    func testATapOfTheMoshKeyBetweenTwoFramesStillMoshesForOne() {
        let registry = ParamRegistry()
        let node = DatamoshNode(identifier: "fx", context: nil)
        registry.register(slot: "fx", parameters: node.parameters)
        registry.setValue(1, slot: "fx", code: .moshHold)
        registry.setValue(0, slot: "fx", code: .moshHold)   // released before any frame
        node.applyParameters(from: registry)
        XCTAssertTrue(node.isHeld, "the tap is latched, so it moshes for a frame")
        node.applyParameters(from: registry)
        XCTAssertTrue(node.isHeld, "not consumed until a frame renders")
    }

    func testHoldingMoshMoshesContinuousFootageWithNoCutThenEasesOutOnRelease() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal") }
        let motion = try clip("motion.mov", count: 60)
        let node = DatamoshNode(identifier: "test.mosh.hold", context: metal)
        let uploader = TextureUploader(context: metal, label: "test-hold")
        let readback = try XCTUnwrap(OffscreenRenderer(context: metal))
        // Every fader at zero: only the key is asking for anything.
        func step(_ index: Int) throws -> MTLTexture? {
            let input = try XCTUnwrap(uploader.upload(motion[index % motion.count]))
            let rendered = node.render(inputs: [input], context: RenderContext(
                frameIndex: index, presentationTime: Double(index) / 29.97, musicalPosition: nil))
            metal.waitForIdle()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 29.97))
            return rendered
        }
        _ = try step(0)
        XCTAssertFalse(node.isRunning, "idle before the key")

        node.hold = 1
        var picture: ImageBuffer?
        for index in 1..<45 {
            if let rendered = try step(index), index == 44 { picture = readback.readback(rendered) }
        }
        XCTAssertTrue(node.isRunning)
        XCTAssertGreaterThan(node.statistics.bloomed, 20, "held, the loop replays: \(node.statistics)")
        let moshed = try XCTUnwrap(picture)
        let source = motion[43]
        var total = 0
        for index in stride(from: 0, to: min(moshed.pixels.count, source.pixels.count), by: 4) {
            total += abs(Int(moshed.pixels[index]) - Int(source.pixels[index]))
        }
        let difference = Double(total) / Double(moshed.width * moshed.height)
        XCTAssertGreaterThan(difference, 8, "a mosh with no cut in the footage (diff \(difference))")

        // Let go with the faders at zero: the same eased exit as pulling them down.
        node.hold = 0
        var releaseFrames = 0
        while node.isRunning && releaseFrames < 100 {
            _ = try step(100 + releaseFrames)
            releaseFrames += 1
        }
        XCTAssertEqual(releaseFrames, MoshHealEnvelope.frames(fromNormalised: DatamoshNode.defaultHealTime),
                       "released after the heal time, not at once")
    }

    func testHealIsArmedOnTheBeatThroughHealEvery() throws {
        let card = try XCTUnwrap(ModuleCatalog.nativeModules().first { $0.id == ModuleCatalog.ID.datamosh })
        let heal = try XCTUnwrap(card.controls.first { $0.code == .moshHeal })
        let arm = try XCTUnwrap(heal.beatArm, "HEAL can be armed on the beat")
        XCTAssertEqual(arm.code, .moshHealEvery)
        XCTAssertEqual(MoshHealEvery.from(normalised: arm.armedValue), .beat)
        XCTAssertFalse(arm.isArmed(0), "heal every off is not armed")
        XCTAssertTrue(arm.isArmed(MoshHealEvery.bar.normalisedPosition))
        XCTAssertTrue(card.controls.contains { $0.code == .moshHold && $0.kind == .trigger },
                      "the MOSH key is on the card")
    }

    func testTheSwitchAndAnInstantHealTimeStillLetGoAtOnce() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal") }
        let node = DatamoshNode(identifier: "test.mosh.instant", context: metal)
        let uploader = TextureUploader(context: metal, label: "test-instant")
        let input = try XCTUnwrap(uploader.upload(ImageBuffer(width: 64, height: 48)))
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        node.mosh = 0.5
        _ = node.render(inputs: [input], context: context)
        XCTAssertTrue(node.isRunning)
        node.wetDry = 0
        XCTAssertTrue(node.render(inputs: [input], context: context) === input, "the switch is a bypass: at once")
        XCTAssertFalse(node.isRunning)

        node.wetDry = 1
        node.healTime = 0
        _ = node.render(inputs: [input], context: context)
        XCTAssertTrue(node.isRunning)
        node.mosh = 0
        XCTAssertTrue(node.render(inputs: [input], context: context) === input, "heal time 0: let go at once")
        XCTAssertFalse(node.isRunning)
    }
}
