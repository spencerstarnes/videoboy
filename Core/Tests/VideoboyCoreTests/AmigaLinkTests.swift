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

    func testTwoLinesOfTitleBothSurvive() {
        // Coalescing is per verb, which would collapse a two-line title into one line.
        // TEXT is keyed by WHICH LINE it is instead. Scala really does carry several —
        // see selfqa/out/emu-probe/13-two-texts-on-one-page.png.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        bridge.send([
            ScalaLingo.text(x: 20, y: 40, "TOP", line: 0),
            ScalaLingo.text(x: 20, y: 200, "BOTTOM", line: 1)
        ])
        bridge.flush()
        XCTAssertEqual(transport.allLines.filter { $0.hasPrefix("TEXT") }.count, 2)
    }

    func testDraggingOneLineDoesNotLeaveATrailOfCopies() {
        // The same line at twenty positions is ONE line that moved, not twenty lines.
        // Keyed by coordinates, every position survived and all of them landed.
        let transport = RecordingTransport()
        let bridge = AmigaCommandBridge(transport: transport)
        for y in stride(from: 40, through: 400, by: 20) {
            bridge.send([ScalaLingo.text(x: 20, y: y, "VIDEOBOY", line: 0)])
        }
        bridge.flush()
        let texts = transport.allLines.filter { $0.hasPrefix("TEXT") }
        XCTAssertEqual(texts.count, 1, "a trail was left: \(texts)")
        XCTAssertTrue(texts[0].contains(" 400 "))
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

    func testWithoutAKickstartTheMachineStillComesUpAndSaysWhatItIs() {
        // This assertion USED to be "AROS can only be an A500". That was reasoning
        // from AROS being described as an A500-era ROM replacement, and running it
        // disproved it: FS-UAE's AROS comes up titled "Amiga 1200" and boots a disc.
        //
        // So the requested machine is honoured. What must NOT happen is the panel
        // showing an A1200 while quietly saying nothing about the firmware underneath
        // it, because AROS is a reimplementation and 1990s commercial software is
        // exactly the category that notices — Scala's scalamm.gfx device does not load
        // under it.
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertEqual(configuration.amigaModel, "A1200")
        XCTAssertNotNil(configuration.firmware.note, "it has to say what it is running on")
        XCTAssertTrue(configuration.firmware.note?.contains("AROS") ?? false)
    }

    func testAnA500ProgramStillGetsAnA500() {
        let plain = TitlerProgram(
            name: "Broadcast Titler II", platform: .amiga, requires: [], boot: [],
            machine: .amiga500)
        let configuration = FSUAEConfiguration(
            program: plain, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertEqual(configuration.amigaModel, "A500")
        XCTAssertEqual(
            configuration.fastMemory, 0,
            "a large autoconfig space on an AROS A500 is the fastest way to a machine "
                + "that will not boot, and the titler does not need it")
    }

    func testTheBootDriveComesFirstOrTheMachineHasNoOperatingSystem() {
        // FS-UAE boots the lowest-numbered drive. A shared drawer in slot 0 gives a
        // machine that comes up to an empty screen with no explanation — which is
        // exactly what happened before the system drive existed.
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"),
            systemDrive: URL(fileURLWithPath: "/tmp/sys"))
        let text = configuration.text
        guard let system = text.range(of: "hard_drive_0 = /tmp/sys"),
              let shared = text.range(of: "hard_drive_1 = /tmp/vb") else {
            return XCTFail("expected the system drive in slot 0, got:\n\(text)")
        }
        XCTAssertLessThan(system.lowerBound, shared.lowerBound)
    }

    func testTheSystemVolumeKeepsTheDiscsNameSoStoredPathsResolve() {
        // Software stores absolute paths in its preferences. Scala's config lists
        // `CUCD19:SCALA/BACKGROUNDS/`, so a volume called anything else turns every
        // load into a file requester.
        var configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"),
            systemDrive: URL(fileURLWithPath: "/tmp/sys"))
        configuration.systemVolumeName = "CUCD19"
        XCTAssertTrue(configuration.text.contains("hard_drive_0_label = CUCD19"))
    }

    func testTheMachineRunsAsItsSoftwareExpectsRatherThanAsTheOutputDoes() {
        // Every instinct says match the 480i NTSC output chain. The software is
        // PAL-authored — 640x512 pages, and its own preferences ask for pal.monitor —
        // so an NTSC machine crops it. The capture resamples into the project's
        // 720x480 either way, so matching the software costs nothing and matching the
        // output costs the top and bottom of every page.
        let configuration = FSUAEConfiguration(
            program: scala, firmware: .aros,
            sharedDrawer: URL(fileURLWithPath: "/tmp/vb"))
        XCTAssertTrue(configuration.text.contains("ntsc_mode = 0"))
    }

    // MARK: - Assembling a bootable drive

    func testADirectoryWithoutTheEssentialDrawersIsRefused() throws {
        let empty = try temporaryDrawer()
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(AmigaSystemInstaller.looksBootable(empty))

        let installer = AmigaSystemInstaller(destination: try temporaryDrawer())
        XCTAssertThrowsError(try installer.install(from: empty)) { error in
            // The message has to say what to do, not only what is wrong.
            XCTAssertTrue(
                (error as? AmigaSystemInstaller.InstallError)?
                    .errorDescription?.contains("C, L, Libs and S") ?? false)
        }
    }

    func testABootableDiscIsRecognisedAndCopied() throws {
        let source = try temporaryDrawer()
        for drawer in ["C", "L", "Libs", "S", "System", "Rexxc"] {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(drawer), withIntermediateDirectories: true)
        }
        try "old".write(
            to: source.appendingPathComponent("S/Startup-Sequence"),
            atomically: true, encoding: .utf8)
        XCTAssertTrue(AmigaSystemInstaller.looksBootable(source))

        let destination = try temporaryDrawer()
        let installer = AmigaSystemInstaller(destination: destination)
        let result = try installer.install(from: source)

        XCTAssertTrue(result.copiedDrawers.contains("C"))
        XCTAssertTrue(result.skippedDrawers.contains("Scala"), "absent drawers are reported")
        XCTAssertTrue(installer.isInstalled)

        // The disc's own startup is replaced but KEPT, because it is the only record of
        // what the disc intended to do.
        let startup = try String(
            contentsOf: destination.appendingPathComponent("S/Startup-Sequence"),
            encoding: .isoLatin1)
        XCTAssertTrue(startup.contains("RexxMast"), "ARexx has to come up")
        XCTAssertTrue(startup.contains("VBLink.rexx"), "and so does the listener")
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("S/Startup-Sequence.original"),
                encoding: .utf8),
            "old")
    }

    func testTheStartupBringsThingsUpInAnOrderThatCanWork() {
        // ARexx before the listener, because a listener that starts first forwards
        // into a port that does not exist yet and drops everything.
        let startup = AmigaSystemInstaller(
            destination: URL(fileURLWithPath: "/tmp/x")
        ).startupSequence(titlerPath: "SYS:Scala/ScalaMM")

        guard let rexx = startup.range(of: "RexxMast"),
              let listener = startup.range(of: "VBLink.rexx"),
              let titler = startup.range(of: "SYS:Scala/ScalaMM") else {
            return XCTFail("expected all three to be started")
        }
        XCTAssertLessThan(rexx.lowerBound, listener.lowerBound)
        XCTAssertLessThan(listener.lowerBound, titler.lowerBound)
        XCTAssertTrue(startup.allSatisfy(\.isASCII))
    }

    func testTheStartupPutsTheTitlersDevicesWhereOpenDeviceLooks() {
        // THIS TEST USED TO ASSERT THE BUG. It insisted on
        // `Assign DEVS: SYS:Scala/System ADD`, which I wrote believing it was the fix
        // and which actually makes the module UNREACHABLE: exec asks for
        // "scalamm.gfx", and with DEVS: pointing at .../System the relative form
        // resolves to System/System/scalamm.gfx.
        //
        // A test that pins a mistake is worse than no test — it defends it. What
        // matters is that the modules end up where exec looks them up BY NAME, which
        // for a device is DEVS: and for a library is LIBS:.
        let startup = AmigaSystemInstaller(
            destination: URL(fileURLWithPath: "/tmp/x")
        ).startupSequence(titlerPath: "SYS:Scala/ScalaMMPlayer -rexx")
        XCTAssertTrue(startup.contains("SYS:Devs"))
        XCTAssertTrue(startup.contains("SYS:Libs"))
        XCTAssertFalse(startup.contains("Assign DEVS: SYS:Scala/System"))
    }

    func testTheListenerReportsItsOwnHealthRatherThanRelyingOnARedirect() {
        // The first attempt redirected the listener's console output to a file in the
        // shared drawer — a free diagnostic channel, apparently. It is not: ARexx
        // BUFFERS its output, so the file stays empty until the script exits, and a
        // watch loop never exits. The file existed, was zero bytes, and told us
        // nothing while the listener sat there working perfectly.
        //
        // The listener writes its own status file instead, closed on every write, so
        // it is flushed every time. It reports two DIFFERENT facts — that the listener
        // is alive, and whether the program's port is open — and telling those apart
        // is most of diagnosing this link.
        let script = AmigaSideScripts.listener()
        XCTAssertTrue(script.contains("link.status"))
        XCTAssertTrue(script.contains("'port open'"))
        XCTAssertTrue(script.contains("'port closed'"))

        let startup = AmigaSystemInstaller(
            destination: URL(fileURLWithPath: "/tmp/x")
        ).startupSequence(titlerPath: "")
        XCTAssertFalse(
            startup.contains("link-out.txt"),
            "redirecting a watch loop's output to a file produces an empty file")
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

/// Where the titler's modules have to land, learnt the hard way.
final class TitlerModulePlacementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private var startup: String {
        AmigaSystemInstaller(destination: URL(fileURLWithPath: "/tmp/x"))
            .startupSequence(titlerPath: "SYS:Scala/ScalaMMPlayer -rexx")
    }

    func testTheDeviceGoesToDEVSAndTheLibraryToLIBS() {
        // Read out of the binaries themselves rather than guessed:
        //   scalamm.gfx  romtag NT_DEVICE,  name "scalamm.gfx"  -> DEVS:
        //   scalamm.sys  romtag NT_LIBRARY, name "scalamm.sys"  -> LIBS:
        // Exec looks them up BY NAME, so they have to be in those drawers flat.
        XCTAssertTrue(startup.contains("SYS:Devs"), "the device needs DEVS:")
        XCTAssertTrue(startup.contains("SYS:Libs"), "the library needs LIBS:")
    }

    func testTheOldWRONGAssignIsGone() {
        // THE BUG THIS FILE EXISTS FOR. `Assign DEVS: SYS:Scala/System ADD` resolves
        // the relative form `System/scalamm.gfx` to `System/System/scalamm.gfx`, so the
        // module was never reachable. I diagnosed that early, wrote the fix, and the
        // patch silently failed to apply — so every experiment afterwards was run
        // against a machine where the module could not be found, and every conclusion
        // drawn from them was worthless.
        XCTAssertFalse(
            startup.contains("Assign DEVS: SYS:Scala/System"),
            "this assign makes the device unreachable and reads as though it helps")
    }

    func testTheModulesAreCopiedRatherThanAssigned() {
        // A copy is verifiable from the host — the file is either in the drawer or it
        // is not. An assign is a promise about lookup that can be silently wrong, which
        // is exactly how this went unnoticed.
        XCTAssertTrue(startup.contains("C:Copy"), "modules are copied into place")
    }
}
