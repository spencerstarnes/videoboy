//
//  EmulatedTitlerTests.swift — the emulated titler, as far as it can be tested here.
//
//  No core, no Kickstart ROM and no disk images are present, and none can be supplied
//  by this repository — they are copyrighted and user-owned. So what is tested is
//  everything AROUND the emulator: the boot recipes, the plumbing, and above all that
//  the missing-core path degrades to something labelled rather than crashing.
//

import XCTest
@testable import VideoboyCore

final class EmulatedTitlerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private var broadcastTitler: TitlerProgram {
        TitlerLibrary.programs.first { $0.name == "Broadcast Titler II" }!
    }

    // MARK: - The state every machine is in until someone supplies the assets

    func testAMissingCoreIsALabelledStateNotACrash() {
        let host = UnavailableEmulatorHost(reason: "No Amiga core installed")
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)

        XCTAssertFalse(node.boot(broadcastTitler))
        XCTAssertFalse(node.isRunning)
        XCTAssertEqual(host.unavailableReason, "No Amiga core installed")
        // And it must still behave as a node.
        XCTAssertNil(node.render(
            inputs: [],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)))
    }

    func testTypingAtAnAbsentEmulatorIsHarmless() {
        let node = EmulatedTitlerNode(
            identifier: "emu", host: UnavailableEmulatorHost(reason: "none"), context: nil)
        node.type("HELLO")
        node.press("return")
        XCTAssertFalse(node.isRunning)
    }

    // MARK: - Boot recipes

    func testEveryProgramSaysWhatItNeeds() {
        for program in TitlerLibrary.programs {
            XCTAssertFalse(
                program.requires.isEmpty,
                "\(program.name) must list what a person has to supply — a program that "
                    + "just fails to start teaches nobody what is missing")
            XCTAssertFalse(program.boot.isEmpty, "\(program.name) has no boot recipe")
        }
    }

    func testRecipesLandViaASaveStateRatherThanTimedKeystrokes() {
        // The reliable way into a program is a save state taken at the screen you
        // want. Driving a boot by timed keypresses breaks the moment a disk loads a
        // second slower, and every later step then lands in the wrong place.
        for program in TitlerLibrary.programs {
            let usesState = program.boot.contains {
                if case .loadState = $0 { return true } else { return false }
            }
            XCTAssertTrue(usesState, "\(program.name) should land via a save state")
        }
    }

    func testEveryProgramNamesWhatItNeedsWithoutBundlingIt() {
        // This used to insist on the word "core", from when the plan was a libretro
        // core. It is an emulator now — Amiberry, or FS-UAE — because a core would have
        // to sit as a GPL dylib beside a process we control, while an application we
        // launch and never link is the cleanest compliance there is.
        //
        // The INTENT is unchanged and is the point: every program says what has to be
        // supplied, so nothing is quietly expected to be bundled.
        let emulatorWords = ["core", "amiberry", "fs-uae", "emulator"]
        for program in TitlerLibrary.programs {
            XCTAssertFalse(program.platform.suggestedCore.isEmpty)
            XCTAssertTrue(
                program.requires.contains { requirement in
                    emulatorWords.contains { requirement.lowercased().contains($0) }
                },
                "\(program.name) must say which emulator it needs")
            XCTAssertTrue(
                program.requires.contains { $0.lowercased().contains("kickstart") },
                "\(program.name) must say a Kickstart is the user's to supply")
        }
    }

    // MARK: - Driving it by COMMAND rather than by faked keystrokes

    func testScalaIsDrivenThroughItsScriptPort() {
        guard let scala = TitlerLibrary.programs.first(where: { $0.name == "Scala MM300" }) else {
            return XCTFail("Scala MM300 is not in the library")
        }
        // The port name was GUESSED as "SCALA" and is actually `rexx_ScalaMM`, per
        // Scala/ARexx/Dir.scala on the disc. A wrong port name is invisible: the
        // commands leave, nothing receives them, and every fader moves and changes
        // nothing. This pins it to what the disc says.
        XCTAssertEqual(scala.scriptPort, "rexx_ScalaMM")
        XCTAssertEqual(scala.scriptPort, ScalaLingo.portName)
    }

    func testSettingTextBecomesOneCommandNotAKeystrokeSequence() {
        let command = ScalaLingo.text(x: 20, y: 40, "LIVE FROM THE BASEMENT")
        XCTAssertEqual(command.line, "TEXT 20 40 \"LIVE FROM THE BASEMENT\"")
    }

    func testAQuoteInTheTextDoesNotBreakTheCommand() {
        // A title containing a quote is a normal thing to want and a normal way to
        // end up sending a malformed script line — one that would swallow every
        // argument after it.
        let command = ScalaLingo.text(x: 0, y: 0, "SAY \"HELLO\"")
        XCTAssertEqual(command.line.filter { $0 == "\"" }.count, 2,
                       "exactly the two quotes that delimit the argument")
        XCTAssertTrue(command.line.contains("'HELLO'"))
    }

    func testNumbersAreWrittenTheWayScalaWritesThem() {
        // The disc writes `speed 5`, never `speed 5.0`. A trailing `.0` is the kind of
        // thing a 1995 parser rejects without saying why.
        XCTAssertEqual(ScalaLingo.wipe("fade", speed: 5).line, "WIPE fade SPEED 5")
        XCTAssertEqual(ScalaLingo.pause(seconds: -1).line, "PAUSE -1")
    }

    func testRawCommandsArePassedThroughUntouched() {
        // A wrapper that cannot express what the underlying system can is one people
        // work around rather than with.
        XCTAssertEqual(TitlerCommand.raw("SHOWPAGE 3").line, "SHOWPAGE 3")
    }

    func testCommandsReachTheProgram() {
        let host = MockEmulatorHost()
        XCTAssertTrue(host.supportsCommands)
        _ = host.boot(TitlerLibrary.programs.first { $0.name == "Scala MM300" }!)

        host.send(.command(ScalaLingo.text(x: 20, y: 40, "ON AIR")))
        host.send(.command(ScalaLingo.goTo(event: "Titles")))

        XCTAssertEqual(host.commands.map(\.line), [
            "TEXT 20 40 \"ON AIR\"",
            "GOTO \"Titles\""
        ])
    }

    func testAHostWithNoScriptPortSaysSo() {
        XCTAssertFalse(UnavailableEmulatorHost(reason: "none").supportsCommands)
    }

    // MARK: - Machines

    func testScalaAsksForAnAcceleratedA1200RatherThanAStockMachine() {
        guard let scala = TitlerLibrary.programs.first(where: { $0.name == "Scala MM300" }) else {
            return XCTFail("Scala MM300 is not in the library")
        }
        XCTAssertEqual(scala.machine, .amiga1200Vampire)
        // The distinction that matters: Scala is an authoring environment, not a
        // titler, and a stock A500 either crawls or refuses.
        XCTAssertNotEqual(scala.machine, .amiga500)
    }

    func testEachMachineConfiguresTheCoreDifferently() {
        let stock = TitlerProgram.Machine.amiga500.coreOptions
        let a1200 = TitlerProgram.Machine.amiga1200.coreOptions
        let vampire = TitlerProgram.Machine.amiga1200Vampire.coreOptions

        XCTAssertEqual(stock["puae_model"], "A500")
        XCTAssertEqual(a1200["puae_model"], "A1200")
        XCTAssertNotEqual(a1200["puae_fastmem"], vampire["puae_fastmem"],
                          "an accelerated machine has more fast RAM, and the core has to be told")
        XCTAssertEqual(vampire["puae_cpu_compatibility"], "turbo")
    }

    func testTheVampireIsApproximatedRatherThanClaimed() {
        // PUAE has no 68080. The accelerated profile picks the fastest CPU it does
        // offer, which runs the software comfortably — it is not a cycle-accurate
        // Vampire and the code should not imply that it is.
        let vampire = TitlerProgram.Machine.amiga1200Vampire.coreOptions
        XCTAssertEqual(vampire["puae_cpu_model"], "68040")
        XCTAssertNotEqual(vampire["puae_cpu_model"], "68080")
    }

    func testEveryMachineHasAName() {
        for machine in [TitlerProgram.Machine.amiga500, .amiga1200, .amiga1200Vampire] {
            XCTAssertFalse(machine.displayName.isEmpty)
            XCTAssertFalse(machine.coreOptions.isEmpty)
        }
    }

    // MARK: - Driving it, against a mock

    func testBootingRunsTheRecipeInOrder() {
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)

        XCTAssertTrue(node.boot(broadcastTitler))
        XCTAssertEqual(host.bootedProgram?.name, "Broadcast Titler II")
        XCTAssertEqual(host.received, broadcastTitler.boot, "the recipe must run as written")
    }

    func testTextReachesTheProgram() {
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        _ = node.boot(broadcastTitler)

        node.type("LIVE FROM")
        node.type(" THE BASEMENT")

        XCTAssertEqual(
            host.typedText, "LIVE FROM THE BASEMENT",
            "this is the whole point — a modern text box driving vintage software")
    }

    func testAControlPressIsSentAsAKeyNotAsText() {
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        _ = node.boot(broadcastTitler)
        node.press("f1")

        XCTAssertTrue(host.received.contains(.key("f1")))
        XCTAssertEqual(host.typedText, "", "a function key is not typed text")
    }

    func testARunningEmulatorReportsItselfAsASource() {
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        XCTAssertFalse(node.isRunning, "nothing booted yet")
        _ = node.boot(broadcastTitler)
        XCTAssertTrue(node.isRunning, "a booted emulator is a source the graph can use")
    }

    func testShutdownLeavesNothingBehind() {
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        _ = node.boot(broadcastTitler)
        host.shutdown()
        XCTAssertFalse(node.isRunning)
        XCTAssertNil(host.latestFrame())
    }

    // MARK: - Boot step descriptions, which the panel shows while it loads

    func testEveryStepCanDescribeItself() {
        let steps: [TitlerBootStep] = [
            .wait(seconds: 1.5), .waitForStableScreen(timeout: 30), .key("return"),
            .type("HELLO"), .click(x: 0.5, y: 0.25), .loadState(named: "entry")
        ]
        for step in steps {
            XCTAssertFalse(step.description.isEmpty)
        }
    }
}

// MARK: - The core system

final class EmulatorCoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private var directory: URL!

    private func makeLibrary() -> CoreLibrary {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-cores-\(UUID().uuidString)")
        let cores = directory.appendingPathComponent("cores")
        let system = directory.appendingPathComponent("system")
        try? FileManager.default.createDirectory(at: cores, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        return CoreLibrary(coresDirectory: cores, systemDirectory: system)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func place(_ name: String, in folder: String) {
        let url = directory.appendingPathComponent(folder).appendingPathComponent(name)
        try? Data([0]).write(to: url)
    }

    func testNothingInstalledIsReportedClearlyRatherThanAsFailure() {
        let library = makeLibrary()
        let statuses = library.status()
        XCTAssertFalse(statuses.isEmpty, "the app should still list cores it knows about")
        for status in statuses {
            XCTAssertFalse(status.isInstalled)
            XCTAssertFalse(status.isRunnable)
            XCTAssertTrue(
                status.summary.contains("not installed"),
                "the summary must say what to DO, not only that something is wrong")
        }
    }

    func testACoreWithoutItsSystemFileIsNotRunnable() {
        let library = makeLibrary()
        place("puae_libretro.dylib", in: "cores")

        guard let amiga = library.status().first(where: { $0.core.platform == .amiga }) else {
            return XCTFail("no Amiga core listed")
        }
        XCTAssertTrue(amiga.isInstalled)
        XCTAssertFalse(amiga.isRunnable, "a core without its Kickstart cannot run anything")
        XCTAssertEqual(amiga.missingSystemFiles, ["kick34005.A500.rom"])
        XCTAssertTrue(amiga.summary.contains("kick34005"))
    }

    func testACoreWithEverythingPresentIsRunnable() {
        let library = makeLibrary()
        place("puae_libretro.dylib", in: "cores")
        place("kick34005.A500.rom", in: "system")

        guard let amiga = library.status().first(where: { $0.core.platform == .amiga }) else {
            return XCTFail("no Amiga core listed")
        }
        XCTAssertTrue(amiga.isRunnable)
        XCTAssertEqual(amiga.summary, "PUAE (Amiga) is ready")
    }

    func testAProgramKnowsWhyItCannotRun() {
        let library = makeLibrary()
        let titler = TitlerLibrary.programs.first { $0.name == "Broadcast Titler II" }!

        XCTAssertFalse(library.canRun(titler))
        XCTAssertNotNil(library.blockedReason(for: titler))

        place("puae_libretro.dylib", in: "cores")
        place("kick34005.A500.rom", in: "system")
        XCTAssertTrue(library.canRun(titler))
        XCTAssertNil(library.blockedReason(for: titler), "nothing should be blocking it now")
    }

    func testACoreCopiedFromAnotherMachineIsStillRecognised() {
        // Cores are often copied out of another machine's RetroArch folder, where they
        // may carry a .so rather than a .dylib. Refusing one on its extension alone
        // would be unhelpful and would look like the core was missing.
        let library = makeLibrary()
        place("dosbox_pure_libretro.so", in: "cores")
        XCTAssertTrue(
            library.status().first { $0.core.platform == .dos }?.isInstalled ?? false)
    }

    func testEveryKnownCoreSaysWhereToGetItWithoutFetchingIt() {
        for core in CoreLibrary.known {
            XCTAssertFalse(
                core.whereToGet.isEmpty,
                "\(core.displayName) must tell someone how to obtain it — this app "
                    + "never downloads a core, so the instructions are the feature")
        }
    }
}

// MARK: - The translation layer

/// The rule this suite exists to enforce: every control on the panel must become a
/// command the software actually understands. A slider that moves and changes nothing
/// is worse than no slider, because it teaches you to distrust the whole panel.
final class TitlerControlTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private var scala: TitlerProgram {
        TitlerLibrary.programs.first { $0.name == "Scala MM300" }!
    }

    func testScalaHasAPanelBecauseItHasAScriptPort() {
        XCTAssertFalse(TitlerControlSet.controls(for: scala).isEmpty)
    }

    func testAProgramWithNoScriptPortOffersNoControls() {
        // Rather than offering knobs that cannot reach anything.
        let unscripted = TitlerProgram(
            name: "Something", platform: .amiga, requires: [], boot: [])
        XCTAssertTrue(TitlerControlSet.controls(for: unscripted).isEmpty)
    }

    func testEveryControlProducesACommandAtEveryPosition() {
        let panel = ScalaTitlerPanel()
        for control in TitlerControlSet.controls(for: scala) {
            // The two that genuinely have nothing behind them yet say so rather than
            // inventing a command, and are checked separately below.
            guard panel.unavailableReason(for: control.function) == nil else { continue }
            for step in 0...20 {
                let commands = panel.set(control.function, to: Double(step) / 20.0)
                XCTAssertFalse(
                    commands.isEmpty, "\(control.name) produced nothing at \(step)/20")
                for command in commands {
                    XCTAssertFalse(command.line.isEmpty)
                }
            }
        }
    }

    func testTheEndsOfAFaderReachTheEndsOfTheRange() {
        let panel = ScalaTitlerPanel()
        // Scala's only text scale is the font size, and the whole 12...114pt span the
        // disc uses has to be reachable — the two ends are a caption and a
        // full-screen word.
        _ = panel.set(.fontSize, to: 0)
        XCTAssertEqual(panel.state.fontSize, ScalaLingo.fontSizeRange.lowerBound)
        _ = panel.set(.fontSize, to: 1)
        XCTAssertEqual(panel.state.fontSize, ScalaLingo.fontSizeRange.upperBound)
    }

    func testTheSpeedFaderIsInvertedBecauseScalaCountsBackwards() {
        // Scala's speed 1 is the FAST one. A fader labelled SPEED that slows down as
        // it goes up is the kind of small wrongness that makes a whole panel
        // untrustworthy.
        let panel = ScalaTitlerPanel()
        _ = panel.set(.wipeSpeed, to: 1)
        let atTop = panel.state.wipeSpeed
        _ = panel.set(.wipeSpeed, to: 0)
        XCTAssertLessThan(atTop, panel.state.wipeSpeed, "up the fader must mean faster")
        XCTAssertEqual(atTop, ScalaLingo.speedRange.lowerBound)
    }

    func testAChoiceControlWalksItsWholeSet() {
        let panel = ScalaTitlerPanel()
        var seen: Set<String> = []
        for step in 0...500 {
            _ = panel.set(.wipe, to: Double(step) / 500.0)
            seen.insert(ScalaLingo.wipes[panel.state.wipeIndex])
        }
        XCTAssertEqual(
            seen.count, ScalaLingo.wipes.count,
            "every one of Scala's \(ScalaLingo.wipes.count) wipes must be reachable "
                + "from some fader position, or it may as well not exist")
    }

    func testEveryWipeNameCameOffTheDisc() {
        // The guard against the panel drifting back towards plausible-sounding
        // inventions. These are the names Scala's own scripts use.
        for invented in ["WIPELEFT", "WIPERIGHT", "IRIS", "VENETIAN", "SCROLL"] {
            XCTAssertFalse(
                ScalaLingo.wipes.contains(invented.lowercased()),
                "\(invented) was guessed in the first draft and is not a Scala wipe")
        }
        for real in ["nuclear", "ants", "xword", "rollodex", "curtain", "dump"] {
            XCTAssertTrue(ScalaLingo.wipes.contains(real))
        }
    }

    func testColoursStayInsideTheAmigaPalette() {
        // Four bits per gun, so one hex digit each and never more.
        for step in 0...200 {
            let colour = ScalaColour.hue(Double(step) / 200.0)
            XCTAssertEqual(colour.amigaHex.count, 3, "an Amiga colour is three hex digits")
            for character in colour.amigaHex {
                XCTAssertTrue(character.isHexDigit)
            }
        }
    }

    func testTheHueSweepActuallyChangesColour() {
        // A colour fader that returns the same colour everywhere would pass the range
        // check above and be useless.
        var seen: Set<String> = []
        for step in 0...200 { seen.insert(ScalaColour.hue(Double(step) / 200.0).amigaHex) }
        XCTAssertGreaterThan(seen.count, 12, "the hue circle should cover real ground")
    }

    func testANonFiniteValueDoesNotProduceNonsense() {
        // These are driven by faders, LFOs and MIDI, any of which can hand over a NaN.
        let panel = ScalaTitlerPanel()
        for control in TitlerControlSet.controls(for: scala) {
            guard panel.unavailableReason(for: control.function) == nil else { continue }
            for value in [Double.nan, .infinity, -.infinity] {
                let commands = panel.set(control.function, to: value)
                XCTAssertFalse(commands.isEmpty, "\(control.name) gave up on \(value)")
                for command in commands {
                    XCTAssertFalse(command.line.contains("nan"))
                    XCTAssertFalse(command.line.contains("inf"))
                }
            }
        }
    }

    func testAControlWithNothingBehindItSaysWhy() {
        // The house rule: unfinished renders disabled with a reason, never omitted and
        // never faked.
        let panel = ScalaTitlerPanel()
        XCTAssertNotNil(panel.unavailableReason(for: .page))
        XCTAssertTrue(panel.set(.page, to: 0.5).isEmpty)

        panel.pageNames = ["Opening", "Titles", "Credits"]
        XCTAssertNil(panel.unavailableReason(for: .page))
        XCTAssertEqual(panel.set(.page, to: 1).first?.line, "GOTO \"Credits\"")
    }

    func testAFaderThatNeedsOtherFadersReissuesTheWholeLine() {
        // `WIPE curtain south SPEED 10` is ONE line carrying three faders. Moving the
        // speed has to restate the wipe and the direction, or the line is wrong.
        let panel = ScalaTitlerPanel()
        _ = panel.set(.wipe, to: 0)
        _ = panel.set(.wipeDirection, to: 1)
        // A control change now repaints the whole page — Scala only draws pages, so a
        // lone WIPE line would be accepted and never appear. The WIPE inside that page
        // still has to carry all three faders.
        let lines = panel.set(.wipeSpeed, to: 0.5).map(\.line)
        let line = lines.first { $0.hasPrefix("WIPE ") } ?? ""
        XCTAssertTrue(line.hasPrefix("WIPE cut "), "the chosen wipe survived: \(line)")
        XCTAssertTrue(line.contains("backwards"), "and so did the direction: \(line)")
        XCTAssertTrue(line.contains("SPEED"))
    }

    func testTheReadoutIsInScalasUnitsNotTheFadersUnits() {
        // "Franklin 44pt" tells an operator something. "0.31" does not.
        let panel = ScalaTitlerPanel()
        _ = panel.set(.fontSize, to: 1)
        XCTAssertEqual(panel.readout(for: .fontSize), "114pt")
        _ = panel.set(.wipe, to: 0)
        XCTAssertEqual(panel.readout(for: .wipe), "CUT")
    }

    func testBootingSendsTheWholePanelSoTheTwoSidesAgree() {
        // A freshly booted machine has no idea what the faders are showing.
        let lines = ScalaTitlerPanel().fullState().map(\.line)
        XCTAssertTrue(lines.contains { $0.hasPrefix("BLANK") }, "the screen mode")
        XCTAssertTrue(lines.contains { $0.hasPrefix("FONT") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("PALETTE") })
        XCTAssertEqual(lines.last, "SHOW", "and it has to end by revealing the page")
    }

    func testEveryControlExplainsItselfInTermsOfTheSoftware() {
        for control in TitlerControlSet.controls(for: scala) {
            XCTAssertFalse(control.explanation.isEmpty)
            XCTAssertGreaterThan(
                control.explanation.count, 30,
                "\(control.name) needs an explanation of what it does TO SCALA, not a "
                    + "restatement of the widget's name")
        }
    }

    func testAControlDrivenByAFaderReachesTheProgram() {
        // The whole path in miniature: a 0...1 value becomes real Scala Lingo and
        // arrives at the program. The same path was then proved against a real
        // emulated Amiga — see selfqa/out/emu/port-received.log, which is what an
        // ARexx port inside the machine actually received.
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        _ = node.boot(scala)

        let panel = ScalaTitlerPanel()
        for command in panel.set(.wipe, to: 0) {
            host.send(.command(command))
        }

        // The page ends with SHOW, because a page that is painted and never revealed
        // is the bug this whole model exists to prevent.
        XCTAssertEqual(host.commands.last?.line, "SHOW")
        XCTAssertTrue(
            host.commands.contains { $0.line == "WIPE cut SPEED 5" },
            "the fader's own line has to be in the page it repainted")
    }
}
