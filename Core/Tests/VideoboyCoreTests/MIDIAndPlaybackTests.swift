//
//  MIDIAndPlaybackTests.swift — detect/learn, and DV playback with on-beat corruption.
//
//  Purpose : Phase 2's headless acceptance. Proves that shift-to-detect maps a real
//            control to a param code, that the mapped parameter then moves, and that
//            a DV source plays and corrupts on the beat — all without a window, the
//            physical controller, or the HDMI card.
//  Inputs  : a virtual CoreMIDI source, and samples/motion.dv.
//  Outputs : assertions plus PNGs under selfqa/out/phase-2/.
//  Connects: MIDIInput, VirtualMIDISource, DVSourceNode, Transport, Scheduler.
//  Extend  : a new control source should be provable the same way — drive it, assert
//            the parameter moved.
//

import XCTest
@testable import VideoboyCore

final class MIDIAndPlaybackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Detect / learn

    func testDetectMapsTheNextControlAndThenTheParameterMoves() {
        let registry = ParamRegistry()
        let slot = GraphTopology.sourceA
        registry.register(slot: slot, parameters: [
            Parameter(code: .corruptAmount, range: 0...1, defaultValue: 0)
        ])
        let midi = MIDIInput(registry: registry)

        // Nothing is mapped yet, so an incoming knob does nothing.
        let knob = ControlSource.midiControlChange(channel: 0, controller: 21)
        midi.handle(event: ControlEvent(source: knob, value: 0.9))
        XCTAssertEqual(registry.bindings.count, 0)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0, accuracy: 1e-9)

        // Arm detect (the user held Shift and touched the corruptor's amount slider)...
        var detected: ControlBinding?
        midi.onDetectCompleted = { detected = $0 }
        midi.beginDetect(slot: slot, code: .corruptAmount)
        XCTAssertTrue(midi.isDetecting)

        // ...then move a knob.
        midi.handle(event: ControlEvent(source: knob, value: 0.5))

        XCTAssertFalse(midi.isDetecting, "detect must disarm once it has captured a control")
        XCTAssertEqual(detected?.code, .corruptAmount)
        XCTAssertEqual(detected?.slot, slot)
        XCTAssertEqual(detected?.source, knob)
        // The parameter jumps to the control's current position immediately.
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0.5, accuracy: 1e-9)

        // And from then on the knob drives it.
        midi.handle(event: ControlEvent(source: knob, value: 0.8))
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0.8, accuracy: 1e-9)
    }

    func testDetectCanBeCancelled() {
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [Parameter(code: .opacity)])
        let midi = MIDIInput(registry: registry)
        midi.beginDetect(slot: "a", code: .opacity)
        midi.cancelDetect()
        XCTAssertFalse(midi.isDetecting)
        midi.handle(event: ControlEvent(source: .midiNote(channel: 0, note: 60), value: 1))
        XCTAssertEqual(registry.bindings.count, 0, "a cancelled detect must not map anything")
    }

    func testUniversalPacketDecoding() {
        // A Control Change on channel 1, controller 21, value 127.
        // UMP layout: type 2, group 0, status 0xB0, data 21, data 127.
        let controlChange: UInt32 = (0x2 << 28) | (0xB0 << 16) | (21 << 8) | 127
        let event = try! XCTUnwrap(MIDIInput.decode(word: controlChange))
        XCTAssertEqual(event.source, .midiControlChange(channel: 0, controller: 21))
        XCTAssertEqual(event.value, 1.0, accuracy: 1e-9)

        // A Note On, channel 3, note 60, velocity 64.
        let noteOn: UInt32 = (0x2 << 28) | (0x92 << 16) | (60 << 8) | 64
        let note = try! XCTUnwrap(MIDIInput.decode(word: noteOn))
        XCTAssertEqual(note.source, .midiNote(channel: 2, note: 60))
        XCTAssertEqual(note.value, 64.0 / 127.0, accuracy: 1e-9)

        // A Note Off must read as the same address at zero, so a mapping releases.
        let noteOff: UInt32 = (0x2 << 28) | (0x82 << 16) | (60 << 8) | 0
        let off = try! XCTUnwrap(MIDIInput.decode(word: noteOff))
        XCTAssertEqual(off.source, .midiNote(channel: 2, note: 60))
        XCTAssertEqual(off.value, 0, accuracy: 1e-9)

        // A message type this app does not act on is ignored, not guessed at.
        XCTAssertNil(MIDIInput.decode(word: (0x2 << 28) | (0xD0 << 16)))
    }

    /// Drives the real CoreMIDI stack: a virtual source sends, the input receives.
    /// Skipped rather than failed where no MIDI server is available.
    func testVirtualMIDISourceIsVisibleToCoreMIDI() throws {
        guard let source = VirtualMIDISource(name: "Videoboy Test Source") else {
            throw XCTSkip("CoreMIDI is unavailable in this environment")
        }
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [Parameter(code: .corruptAmount)])
        let midi = MIDIInput(registry: registry)
        guard midi.start() else {
            throw XCTSkip("Core MIDI input could not be opened in this environment")
        }

        // Core MIDI delivers on its own thread and needs a moment to notice a new
        // endpoint, so this pumps the run loop and re-sends until something arrives
        // rather than waiting once on a fixed timeout.
        var receivedController: UInt8?
        midi.onEvent = { event in
            if case .midiControlChange(_, let controller) = event.source {
                receivedController = controller
            }
        }

        let deadline = Date().addingTimeInterval(3.0)
        while receivedController == nil && Date() < deadline {
            source.sendControlChange(channel: 0, controller: 21, value: 100)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(
            receivedController, 21,
            "a message sent from the virtual source must arrive at the MIDI input"
        )
        // ...and it must have been delivered through the normal path, not a shortcut.
        XCTAssertEqual(registry.bindings.count, 0, "nothing was armed, so nothing should be mapped")
    }

    // MARK: - Playback

    private func openSource(_ name: String = "motion.dv") throws -> DVSourceNode {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/\(name) is missing — run scripts/make-fixtures.sh")
        }
        let node = DVSourceNode(identifier: GraphTopology.sourceA, context: nil)
        XCTAssertTrue(node.load(url: url), "the DV source must load its file")
        return node
    }

    func testSourceLoadsAndReportsItsLength() throws {
        let node = try openSource()
        XCTAssertGreaterThan(node.frameCount, 100)
        XCTAssertEqual(node.normalisedPosition, 0, accuracy: 1e-9)
    }

    func testMissingFileLeavesTheSourceEmptyRatherThanCrashing() {
        let node = DVSourceNode(identifier: "test", context: nil)
        XCTAssertFalse(node.load(url: URL(fileURLWithPath: "/nonexistent/nope.dv")))
        XCTAssertEqual(node.frameCount, 0)
        XCTAssertNil(node.renderToImage(frameIndex: 0))
    }

    func testSeekAndStepMoveThePlayhead() throws {
        let node = try openSource()
        node.seek(toNormalised: 0.5)
        XCTAssertEqual(node.normalisedPosition, 0.5, accuracy: 0.01)
        node.seek(toNormalised: 0)
        node.step(by: 5)
        XCTAssertEqual(Int(node.normalisedPosition * Double(node.frameCount - 1)), 5)
        // Stepping back past the start wraps rather than going negative.
        node.step(by: -10)
        XCTAssertGreaterThan(node.normalisedPosition, 0.9)
    }

    // MARK: - Loop modes

    func testLoopWrapsAtBothEnds() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.loopMode = .loop

        node.seek(toNormalised: 1.0)
        node.advancePlayhead(by: 5, frameCount: frameCount)
        // Past the end comes round to the start, not to a stop.
        XCTAssertLessThan(node.normalisedPosition, 0.1)

        node.seek(toNormalised: 0.0)
        node.advancePlayhead(by: -5, frameCount: frameCount)
        // ...and backwards past the start comes round to the end.
        XCTAssertGreaterThan(node.normalisedPosition, 0.9)
    }

    func testPingPongTurnsAroundRatherThanWrapping() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.loopMode = .pingPong

        node.seek(toNormalised: 1.0)
        XCTAssertFalse(node.isPlayingBackwards)
        node.advancePlayhead(by: 5, frameCount: frameCount)

        // It must reverse, not jump to the start.
        XCTAssertTrue(node.isPlayingBackwards, "ping-pong must reverse at the end")
        XCTAssertGreaterThan(node.normalisedPosition, 0.9, "it must stay near the end, not wrap")

        // Run it back to the start and it should turn around again.
        for _ in 0..<(frameCount * 2) {
            node.advancePlayhead(by: 5, frameCount: frameCount)
            if !node.isPlayingBackwards { break }
        }
        XCTAssertFalse(node.isPlayingBackwards, "ping-pong must reverse again at the start")
    }

    func testOneShotStopsOnTheLastFrame() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.loopMode = .oneShot
        node.isPlaying = true

        node.seek(toNormalised: 1.0)
        node.advancePlayhead(by: 5, frameCount: frameCount)

        XCTAssertFalse(node.isPlaying, "one shot must stop at the end")
        XCTAssertEqual(node.normalisedPosition, 1.0, accuracy: 0.02,
                       "it must hold the last frame, not wrap or blank")
    }

    // MARK: - Step playback

    func testSteppedPlaybackAdvancesOncePerBoundary() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.loopMode = .loop
        node.seek(toNormalised: 0)

        // One frame per beat.
        let subdivision = Subdivision.quarter
        // The first call establishes the reference rather than stepping, so enabling
        // it part-way through a bar does not jump.
        node.advanceIfBoundaryCrossed(
            totalBeats: 0.3, subdivision: subdivision, frames: 1, frameCount: frameCount)
        XCTAssertEqual(node.normalisedPosition, 0, accuracy: 1e-9, "arming must not step")

        // Still inside beat 0: no step.
        node.advanceIfBoundaryCrossed(
            totalBeats: 0.9, subdivision: subdivision, frames: 1, frameCount: frameCount)
        XCTAssertEqual(node.normalisedPosition, 0, accuracy: 1e-9, "no boundary crossed yet")

        // Crossing into beat 1 steps exactly one frame.
        node.advanceIfBoundaryCrossed(
            totalBeats: 1.1, subdivision: subdivision, frames: 1, frameCount: frameCount)
        XCTAssertEqual(
            Int((node.normalisedPosition * Double(frameCount - 1)).rounded()), 1,
            "crossing one boundary must advance exactly one frame")

        // And again at the next beat.
        node.advanceIfBoundaryCrossed(
            totalBeats: 2.05, subdivision: subdivision, frames: 1, frameCount: frameCount)
        XCTAssertEqual(
            Int((node.normalisedPosition * Double(frameCount - 1)).rounded()), 2)
    }

    func testSteppedPlaybackCatchesUpRatherThanLosingSteps() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.seek(toNormalised: 0)

        node.advanceIfBoundaryCrossed(
            totalBeats: 0.0, subdivision: .quarter, frames: 1, frameCount: frameCount)
        // A late render frame jumps three beats at once. All three steps must happen,
        // or the clip drifts permanently out of phase with the music.
        node.advanceIfBoundaryCrossed(
            totalBeats: 3.2, subdivision: .quarter, frames: 1, frameCount: frameCount)
        XCTAssertEqual(
            Int((node.normalisedPosition * Double(frameCount - 1)).rounded()), 3,
            "three boundaries crossed must advance three frames")
    }

    func testStepSizeMultipliesTheAdvance() throws {
        let node = try openSource()
        let frameCount = node.frameCount
        node.seek(toNormalised: 0)

        // Quad time: four frames per beat.
        node.advanceIfBoundaryCrossed(
            totalBeats: 0.0, subdivision: .quarter, frames: 4, frameCount: frameCount)
        node.advanceIfBoundaryCrossed(
            totalBeats: 1.1, subdivision: .quarter, frames: 4, frameCount: frameCount)
        XCTAssertEqual(
            Int((node.normalisedPosition * Double(frameCount - 1)).rounded()), 4)
    }

    func testSteppedPlaybackHoldsWithTheTransportStopped() throws {
        let node = try openSource()
        node.timing = .stepped(subdivision: .quarter, frames: 1)
        node.isPlaying = true
        node.seek(toNormalised: 0)

        // No musical position means the transport is stopped. A stepped clip takes
        // its timing from the music, so with no music it holds.
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        for _ in 0..<30 { _ = node.render(inputs: [], context: context) }
        XCTAssertEqual(node.normalisedPosition, 0, accuracy: 1e-9)
    }

    func testPlaybackTimingPresetsAndLabels() {
        XCTAssertEqual(PlaybackTiming.continuous.displayName, "Live")
        XCTAssertNil(PlaybackTiming.continuous.beatsPerStep)
        XCTAssertEqual(PlaybackTiming.continuous.framesPerStep, 0)

        let onePerBeat = PlaybackTiming.stepped(subdivision: .quarter, frames: 1)
        XCTAssertEqual(onePerBeat.displayName, "1/4")
        XCTAssertEqual(onePerBeat.beatsPerStep, 1.0)
        XCTAssertEqual(onePerBeat.framesPerStep, 1)

        let quad = PlaybackTiming.stepped(subdivision: .quarter, frames: 4)
        XCTAssertEqual(quad.displayName, "1/4×4")

        // Every preset must explain itself, since "1/8×4" needs saying once.
        for preset in PlaybackTiming.presets {
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertFalse(preset.explanation.isEmpty)
        }
        XCTAssertEqual(PlaybackTiming.presets.count, 7)
    }

    func testLoopModeNames() {
        for mode in LoopMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
        XCTAssertEqual(LoopMode.from(index: 0), .loop)
        XCTAssertEqual(LoopMode.from(index: 1), .pingPong)
        XCTAssertEqual(LoopMode.from(index: 2), .oneShot)
        // Out of range clamps rather than trapping.
        XCTAssertEqual(LoopMode.from(index: 99), .oneShot)
        XCTAssertEqual(LoopMode.from(index: -5), .loop)
    }

    func testPlaybackProducesDifferentPicturesOverTime() throws {
        let node = try openSource()
        let first = try XCTUnwrap(node.renderToImage(frameIndex: 0))
        let later = try XCTUnwrap(node.renderToImage(frameIndex: 60))
        // motion.dv moves, so two seconds apart must look different.
        XCTAssertTrue(FrameAssertions.framesDiffer(first, later, minimumFraction: 0.05).passed)
    }

    /// Phase 2's headline self-visual check: playback plus corruption that changes on
    /// the beat, evidenced by PNGs.
    func testBeatSyncedCorruptionChangesFramesOnTheBeat() throws {
        let node = try openSource()
        let check = SelfQACheck(name: "phase-2/beat-synced-corruption")

        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        // The corruptor re-rolls its seed on every quarter note, compensated for the
        // source's own decode latency so the change lands on the beat.
        node.corruption = CorruptionSettings(mode: .shuffleBlocks, amount: 0.65, seed: 1)
        var reseedCount = 0
        scheduler.subscribe(subdivision: .quarter, latencyInFrames: node.latencyInFrames) { event in
            // Derive the seed from the beat so the performance is reproducible.
            node.rerollCorruptionSeed(using: UInt64(event.targetBeat * 1000) &+ 7)
            reseedCount += 1
        }

        check.note("120 BPM, quarter-note reseed, mode shuffleBlocks at amount 0.65")
        check.note("source latency \(node.latencyInFrames) frame(s), compensated by the scheduler")

        // Render two seconds of project frames, capturing one per beat.
        var imagesByBeat: [Int: ImageBuffer] = [:]
        var seedsSeen: Set<UInt64> = []
        let frameRate = StandardDefinition.frameRate
        let totalFrames = Int(frameRate * 2)

        for frame in 0..<totalFrames {
            let hostTime = Double(frame) / frameRate
            scheduler.advance(to: hostTime)
            seedsSeen.insert(node.corruption.seed)

            // Sample just after each beat boundary, where the new damage is visible.
            let beat = Int(transport.beats(atHostTime: hostTime))
            if imagesByBeat[beat] == nil, transport.beats(atHostTime: hostTime) - Double(beat) < 0.15 {
                // Hold the source frame constant so any difference between samples is
                // the corruption changing, not the picture moving.
                imagesByBeat[beat] = node.renderToImage(frameIndex: 30)
            }
        }

        check.record(AssertionResult(
            name: "scheduler reseeded on the beat",
            passed: reseedCount >= 3,
            detail: "\(reseedCount) reseeds over 2 seconds at 120 BPM (expected about 4)"
        ))
        check.record(AssertionResult(
            name: "each beat used a distinct seed",
            passed: seedsSeen.count >= 4,
            detail: "\(seedsSeen.count) distinct seeds seen"
        ))

        // Write every sampled beat as evidence.
        let beats = imagesByBeat.keys.sorted()
        for beat in beats {
            if let image = imagesByBeat[beat] {
                try check.writeImage(image, named: String(format: "beat-%02d.png", beat))
            }
        }

        // Consecutive beats must look different — that is corruption changing on the
        // beat, on a source frame that is not itself moving.
        var differingPairs = 0
        for index in 1..<max(beats.count, 1) {
            guard let previous = imagesByBeat[beats[index - 1]],
                  let current = imagesByBeat[beats[index]] else { continue }
            if FrameAssertions.differingPixelFraction(previous, current) > 0.02 {
                differingPairs += 1
            }
        }
        check.record(AssertionResult(
            name: "the picture changes from beat to beat",
            passed: differingPairs >= 2,
            detail: "\(differingPairs) of \(max(beats.count - 1, 0)) consecutive beat pairs differ"
        ))

        // ...and all of them must still be valid full-size pictures.
        for beat in beats {
            guard let image = imagesByBeat[beat] else { continue }
            check.record(FrameAssertions.hasDimensions(image, width: 720, height: 480))
        }

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-2/beat-synced-corruption/result.txt")
    }

    func testMappedMIDIDrivesTheCorruptorEndToEnd() throws {
        // The whole control chain, headless: a MIDI knob moves the wedge's amount.
        let node = try openSource()
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        let midi = MIDIInput(registry: registry)

        let knob = ControlSource.midiControlChange(channel: 0, controller: 21)
        midi.beginDetect(slot: node.identifier, code: .corruptAmount)
        midi.handle(event: ControlEvent(source: knob, value: 0.0))
        node.applyParameters(from: registry)
        let clean = try XCTUnwrap(node.renderToImage(frameIndex: 30))

        // Now push the knob up and re-render the same source frame.
        node.corruption.mode = .dropBlocks
        midi.handle(event: ControlEvent(source: knob, value: 1.0))
        node.applyParameters(from: registry)
        XCTAssertEqual(node.corruption.amount, 1.0, accuracy: 1e-9)
        let damaged = try XCTUnwrap(node.renderToImage(frameIndex: 30))

        let difference = FrameAssertions.framesDiffer(
            clean, damaged, minimumFraction: 0.05, name: "MIDI knob damages the picture")
        XCTAssertTrue(difference.passed, difference.detail)
    }
}
