//
//  AmigaLinkTests.swift — the wire into the emulated machine.
//
//  What is checked here is the part that CANNOT be checked by looking at the screen:
//  coalescing, ordering, atomicity and sequence numbering. A dropped command and a
//  command that arrived in the wrong order look identical from outside — a title that
//  is subtly wrong — so each one is pinned separately.
//
//  The end-to-end proof lives in selfqa/out/emu/port-received.log: real commands,
//  logged by an ARexx port inside a real emulated Amiga. These tests are the part of
//  that path that has to keep working without an emulator attached.
//

import XCTest
@testable import VideoboyCore

final class AmigaLinkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Coalescing

    func testAFaderDragCollapsesToOneCommand() {
        // The reason this exists: a dragged fader produces a value per frame. A 68k
        // cannot service sixty commands a second, and — the rule that outranks
        // everything — the render loop must not be waiting on a filesystem.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        let panel = ScalaTitlerPanel()

        for step in 0...60 {
            bridge.send(panel.set(.fontSize, to: Double(step) / 60.0))
        }
        XCTAssertTrue(transport.batches.isEmpty, "sending must not touch the disk")

        bridge.flush()
        let fonts = transport.allLines.filter { $0.hasPrefix("FONT") }
        XCTAssertEqual(fonts.count, 1, "sixty-one moves, one command")
        XCTAssertEqual(fonts.first, "FONT Franklin.font 114", "and it is the LAST value")
    }

    func testOrderIsKeptBecauseScalaCaresAboutIt() {
        // FONT then TEXT draws at the new size. The other way round draws at the old
        // one, which looks like the size fader lagging by one move.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        bridge.send(ScalaTitlerPanel().set(.fontSize, to: 0.5))
        bridge.flush()

        let lines = transport.allLines
        guard let font = lines.firstIndex(where: { $0.hasPrefix("FONT") }),
              let text = lines.firstIndex(where: { $0.hasPrefix("TEXT") }),
              let show = lines.firstIndex(where: { $0 == "SHOW" }) else {
            return XCTFail("expected FONT, TEXT and SHOW, got \(lines)")
        }
        XCTAssertLessThan(font, text)
        XCTAssertLessThan(text, show, "SHOW reveals the page, so it goes last")
    }

    func testTwoPiecesOfTextAtDifferentPlacesBothSurvive() {
        // Coalescing is per verb, which would collapse a two-line title into one line.
        // TEXT is keyed by its coordinates instead.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        bridge.send([
            ScalaLingo.text(x: 20, y: 40, "TOP"),
            ScalaLingo.text(x: 20, y: 200, "BOTTOM")
        ])
        bridge.flush()
        XCTAssertEqual(transport.allLines.filter { $0.hasPrefix("TEXT") }.count, 2)
    }

    func testABootSequenceIsNotCoalesced() {
        // The opposite case: every line of a boot matters and none may be dropped.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        let expectation = expectation(description: "delivered")

        bridge.sendImmediately(ScalaTitlerPanel().fullState())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertGreaterThan(transport.allLines.count, 5)
        XCTAssertEqual(transport.batches.count, 1, "one batch, in order")
    }

    // MARK: - Link state

    func testTheLinkReportsSilenceRatherThanPretending() {
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        XCTAssertEqual(bridge.state, .idle)

        bridge.send([ScalaLingo.show()])
        bridge.flush()
        XCTAssertFalse(bridge.state.isLive, "nothing has answered yet")

        transport.acknowledged = [1]
        bridge.flush()
        XCTAssertTrue(bridge.state.isLive)
    }

    func testAFailedWriteIsReportedNotSwallowed() {
        struct Broken: Error {}
        let transport = RecordingTransport()
        transport.failsWith = Broken()
        let bridge = AmigaCommandBridge(transport: transport)
        bridge.send([ScalaLingo.show()])
        bridge.flush()
        guard case .failed = bridge.state else {
            return XCTFail("a wire that cannot write must say so, got \(bridge.state)")
        }
    }

    // MARK: - The shared drawer

    private func temporaryDrawer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-amiga-\(UUID().uuidString)")
        return url
    }

    func testCommandsLandAsFilesTheAmigaCanSee() throws {
        let root = try temporaryDrawer()
        let transport = try SharedDrawerTransport(root: root)
        try transport.deliver(["WIPE fade SPEED 5", "SHOW"], sequence: 7)

        let file = transport.commandsDirectory.appendingPathComponent("000007.vbc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // Zero-padded, because the Amiga sorts these as text and that is the only way
        // alphabetical order and age agree.
        let body = try String(contentsOf: file, encoding: .isoLatin1)
        XCTAssertEqual(body, "WIPE fade SPEED 5\nSHOW\n")
    }

    func testNoHalfWrittenFileIsEverVisible() throws {
        // The listener only looks at `.vbc`, and a file only becomes one at the
        // rename. Anything else and it can read half a command.
        let root = try temporaryDrawer()
        let transport = try SharedDrawerTransport(root: root)
        try transport.deliver(["SHOW"], sequence: 1)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: transport.commandsDirectory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "a .tmp left behind is a half-written command")
    }

    func testSequenceNumbersSurviveARestart() throws {
        // A REAL BUG THIS CAUGHT. Every run of the CLI built a fresh bridge, which
        // started at 1 and overwrote `000001.vbc` — possibly while the Amiga was
        // reading it. The transport knows what is already in the drawer; the bridge
        // does not.
        let root = try temporaryDrawer()
        let first = try SharedDrawerTransport(root: root)
        XCTAssertEqual(first.startingSequence, 1)
        try first.deliver(["SHOW"], sequence: 1)

        let second = try SharedDrawerTransport(root: root)
        XCTAssertEqual(second.startingSequence, 2, "must not reuse a live file name")
    }

    func testAConsumedCommandStillReservesItsNumber() throws {
        // Once consumed, a command leaves only its acknowledgement. Reusing that
        // number would make the host think a brand-new command had been answered.
        let root = try temporaryDrawer()
        let transport = try SharedDrawerTransport(root: root)
        try "ok".write(
            to: transport.acknowledgementsDirectory.appendingPathComponent("000009.ack"),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(transport.startingSequence, 10)
    }

    func testFSUAEMetadataIsNotMistakenForAnAcknowledgement() throws {
        // FS-UAE drops a `.uaem` beside everything it can see. `000001.ack.uaem` is
        // not an acknowledgement, and counting it would light the link falsely.
        let root = try temporaryDrawer()
        let transport = try SharedDrawerTransport(root: root)
        for name in ["000001.ack", "000001.ack.uaem"] {
            try "ok".write(
                to: transport.acknowledgementsDirectory.appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(transport.acknowledgedSequences(), [1])
    }

    // MARK: - The Amiga side

    func testTheListenerTalksToTheRightPort() {
        let script = AmigaSideScripts.listener()
        XCTAssertTrue(script.contains("rexx_ScalaMM"))
        XCTAssertTrue(script.contains("VB:cmd"))
        XCTAssertTrue(script.contains("VB:ack"))
    }

    func testTheListenerNeedsNoShell() {
        // ANOTHER REAL BUG. The first version listed the drawer with
        // `address command 'list ...'`, which is the idiom the disc's own example
        // uses and which fails on AROS with "Error 13: Host environment not found".
        // rexxsupport's showdir() needs no host at all.
        let script = AmigaSideScripts.listener()
        XCTAssertFalse(
            script.lowercased().contains("address command"),
            "AROS has no COMMAND host, and the listener is the one part that must "
                + "work before anything else can be diagnosed")
        XCTAssertTrue(script.contains("showdir("))
        XCTAssertTrue(script.contains("rexxsupport.library"))
    }

    func testTheListenerClearsWhatItRanAndThenAcknowledges() {
        let script = AmigaSideScripts.listener()
        guard let deleted = script.range(of: "call delete(full)"),
              let acked = script.range(of: ".ack'") ?? script.range(of: "'.ack'") else {
            return XCTFail("the listener must delete and acknowledge")
        }
        XCTAssertLessThan(
            deleted.lowerBound, acked.lowerBound,
            "deleting after acknowledging would replay a command forever if the "
                + "machine died between the two")
    }

    func testTheAmigaSideIsPlainASCII() {
        // These are written as ISO Latin-1 into a machine that predates Unicode. An em
        // dash in a COMMENT failed the whole write the first time this ran.
        for (name, body) in AmigaSideScripts.drawerContents() {
            XCTAssertTrue(
                body.allSatisfy(\.isASCII),
                "\(name) has something outside ASCII in it")
        }
    }

    func testTheStandInPortIsShippedAlongsideTheListener() {
        // Without it, five of the six links in the chain are unverifiable on any
        // machine where the real program will not start.
        XCTAssertNotNil(AmigaSideScripts.drawerContents()["VBEcho.rexx"])
        XCTAssertTrue(AmigaSideScripts.portEcho().contains("openport("))
    }

    func testTheStandInRepliesBeforeItLogs() {
        // The sender is blocked until the reply, and a sender blocked on a log write
        // is a machine that looks hung.
        let script = AmigaSideScripts.portEcho()
        guard let reply = script.range(of: "call reply(pkt, 0)"),
              let log = script.range(of: "open('log'") else {
            return XCTFail("expected a reply and a log write")
        }
        XCTAssertLessThan(reply.lowerBound, log.lowerBound)
    }

    func testTheStandInRefusesToFightTheRealProgram() {
        XCTAssertTrue(
            AmigaSideScripts.portEcho().contains("is already open"),
            "opening a port the real program owns would break the real program")
    }

    // MARK: - The machine

    private var scala: TitlerProgram {
        TitlerLibrary.programs.first { $0.name == "Scala MM300" }!
    }

    func testWithoutAKickstartTheModelStepsDownToWhatAROSCanBe() {
        // AROS is an A500-era ROM replacement. Asking it to be an AGA A1200 produces a
        // machine that does not come up — and an A1200 in the panel that is secretly
        // an A500 is worse than an honest A500.
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertEqual(configuration.amigaModel, "A500")
        XCTAssertEqual(configuration.fastMemory, 0)
        XCTAssertNotNil(configuration.firmware.note, "and it has to say so")
    }

    func testWithAKickstartTheRequestedMachineIsHonoured() {
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .kickstart(path: "/roms/kick31.rom"),
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertEqual(configuration.amigaModel, "A1200")
        XCTAssertEqual(configuration.fastMemory, 64, "the Vampire profile")
        XCTAssertTrue(configuration.text.contains("kickstart_file = /roms/kick31.rom"))
    }

    func testTheSharedDrawerIsMountedAsTheVolumeTheListenerWatches() {
        // Two files that must agree: the config mounts a volume, the listener watches
        // one. If they disagree the machine boots perfectly and ignores everything.
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertTrue(
            configuration.text.contains("hard_drive_0_label = \(AmigaSideScripts.volumeName)"))
        XCTAssertTrue(
            AmigaSideScripts.listener().contains("\(AmigaSideScripts.volumeName):cmd"))
    }

    func testTheWindowIsTitledSoTheCaptureCanFindIt() {
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertTrue(configuration.text.contains("title = Videoboy Amiga"))
        XCTAssertTrue(configuration.text.contains("fullscreen = 0"),
                      "a fullscreen emulator cannot be captured as a window")
    }

    func testWritingTheConfigAlsoWritesTheListener() throws {
        // A config that mounts a drawer with no listener in it produces a machine that
        // boots and then ignores everything, which looks exactly like a bug in the app.
        let root = try temporaryDrawer()
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: root.appendingPathComponent("VB"))
        let written = try configuration.write(to: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        for name in AmigaSideScripts.drawerContents().keys {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("VB/\(name)").path),
                "\(name) was not written beside the config")
        }
    }
}
