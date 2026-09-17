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

    func testEveryProgramNamesACoreWithoutBundlingOne() {
        for program in TitlerLibrary.programs {
            XCTAssertFalse(program.platform.suggestedCore.isEmpty)
            XCTAssertTrue(
                program.requires.contains { $0.lowercased().contains("core") },
                "\(program.name) must say a core is needed")
        }
    }

    // MARK: - Driving it by COMMAND rather than by faked keystrokes

    func testScalaIsDrivenThroughItsScriptPort() {
        guard let scala = TitlerLibrary.programs.first(where: { $0.name == "Scala MM300" }) else {
            return XCTFail("Scala MM300 is not in the library")
        }
        XCTAssertEqual(
            scala.scriptPort, "SCALA",
            "Scala has an ARexx port — driving it by synthesised keystrokes when it "
                + "will take commands is choosing the fragile option")
    }

    func testSettingTextBecomesOneCommandNotAKeystrokeSequence() {
        let command = TitlerCommand.setText(field: "Line1", value: "LIVE FROM THE BASEMENT")
        XCTAssertEqual(command.arexx, "SETTEXT Line1 \"LIVE FROM THE BASEMENT\"")
    }

    func testAQuoteInTheTextDoesNotBreakTheCommand() {
        // A title containing a quote is a normal thing to want and a normal way to
        // end up sending a malformed ARexx line.
        let command = TitlerCommand.setText(field: "Line1", value: "SAY \"HELLO\"")
        XCTAssertFalse(
            command.arexx.dropFirst(8).contains("\"HELLO\""),
            "an embedded quote must not close the argument early")
    }

    func testRawCommandsArePassedThroughUntouched() {
        // A wrapper that cannot express what the underlying system can is one people
        // work around rather than with.
        XCTAssertEqual(TitlerCommand.raw("SHOWPAGE 3").arexx, "SHOWPAGE 3")
    }

    func testCommandsReachTheProgram() {
        let host = MockEmulatorHost()
        XCTAssertTrue(host.supportsCommands)
        _ = host.boot(TitlerLibrary.programs.first { $0.name == "Scala MM300" }!)

        host.send(.command(.setText(field: "Line1", value: "ON AIR")))
        host.send(.command(.goToPage("Titles")))

        XCTAssertEqual(host.commands, [
            .setText(field: "Line1", value: "ON AIR"),
            .goToPage("Titles")
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
        for control in TitlerControlSet.controls(for: scala) {
            for step in 0...20 {
                let command = control.command(for: Double(step) / 20.0)
                XCTAssertFalse(
                    command.arexx.isEmpty,
                    "\(control.name) produced nothing at \(step)/20")
            }
        }
    }

    func testTheEndsOfAFaderReachTheEndsOfTheRange() {
        let page = TitlerControlSet.scalaMM300.first { $0.name == "page" }!
        XCTAssertEqual(page.command(for: 0).arexx, "SET PAGE 1")
        XCTAssertEqual(page.command(for: 1).arexx, "SET PAGE 32")
    }

    func testAChoiceControlWalksItsWholeSet() {
        let wipe = TitlerControlSet.scalaMM300.first { $0.name == "wipe" }!
        var seen: Set<String> = []
        for step in 0...200 { seen.insert(wipe.command(for: Double(step) / 200.0).arexx) }
        guard case .choice(_, let options) = wipe.kind else { return XCTFail("not a choice") }
        XCTAssertEqual(
            seen.count, options.count,
            "every wipe must be reachable from some fader position, or it may as well not exist")
    }

    func testColoursStayInsideTheAmigaPalette() {
        let colour = TitlerControlSet.scalaMM300.first { $0.name == "text col" }!
        for step in 0...50 {
            guard case .setColour(_, let index) = colour.command(for: Double(step) / 50.0) else {
                return XCTFail("expected a colour command")
            }
            XCTAssertTrue(
                (0..<32).contains(index),
                "an Amiga has 32 palette entries; \(index) is not one of them")
        }
    }

    func testANonFiniteValueDoesNotProduceNonsense() {
        // These are driven by faders, LFOs and MIDI, any of which can hand over a NaN.
        for control in TitlerControlSet.controls(for: scala) {
            XCTAssertFalse(control.command(for: .nan).arexx.isEmpty)
            XCTAssertFalse(control.command(for: .infinity).arexx.isEmpty)
        }
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
        // The whole path, end to end: a 0...1 value becomes a command and arrives.
        let host = MockEmulatorHost()
        let node = EmulatedTitlerNode(identifier: "emu", host: host, context: nil)
        _ = node.boot(scala)

        let wipe = TitlerControlSet.scalaMM300.first { $0.name == "wipe" }!
        host.send(.command(wipe.command(for: 0.0)))

        XCTAssertEqual(host.commands.last, .setText(field: "WIPE", value: "CUT"))
    }
}
