//
//  main.swift — the Amiga setup and link CLI.
//
//  Purpose : Get an emulated Amiga running Scala, and let a person poke commands at it
//            by hand. Everything the app does to the machine, this does too — same
//            code, so if it works here it works there.
//  Inputs   : argv.
//  Outputs  : a workspace, an FS-UAE config, the Amiga-side scripts, and a running
//             emulator.
//  Connects : FSUAEConfiguration, AmigaSideScripts, AmigaCommandBridge, ScalaLingo.
//  Extend   : a new verb is a case in `run`. Keep each one doing ONE thing — the value
//             of this tool is being able to test one link in the chain at a time.
//
//  Why an executable and not a shell script: the ARexx listener that runs inside the
//  machine is generated from `AmigaSideScripts`. A bash version would be a second copy
//  of it, the two would drift, and the symptom would be a machine that boots and
//  silently ignores every command.
//

import Foundation
import VideoboyCore

/// Where the workspace lives.
///
/// Outside the repo on purpose: it holds paths to user media and a copy of the
/// emulator's state, neither of which belongs in version control.
let workspace = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Videoboy/amiga")

let sharedDrawer = workspace.appendingPathComponent("VB")

func usage() -> Never {
    print("""
    videoboy-amiga — set up and drive an emulated Amiga.

      setup [--iso <path>] [--kickstart <path>]
            Find what is installed, write the workspace, the FS-UAE config and the
            Amiga-side ARexx listener. Prints what is missing and what it used.

      launch
            Start FS-UAE with the generated config.

      send <line>...
            Post one script line into the machine. `send SHOW`, or
            `send 'TEXT 20 40 "HELLO"'`.

      panel <control> <0..1>
            Move one of the panel's controls and post whatever Scala lines that
            produces. `panel fontSize 0.8`, `panel wipe 0.5`.

      status
            Whether commands are being collected, and whether the Amiga is answering.

      vocabulary
            Print the command vocabulary read off the disc.
    """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let verb = arguments.first else { usage() }

/// The program this tool drives. One for now; the CLI takes a `--program` the day
/// there is a second.
let program = TitlerLibrary.programs.first { $0.name == "Scala MM300" }!

// MARK: - Locating things

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"),
          index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Looks for a disc image in the places a person actually leaves one.
///
/// Desktop and Downloads only. Sweeping the whole home directory for ISO files is
/// slow, surprising, and finds things that are none of this program's business.
func findDiscImage() -> URL? {
    if let given = option("iso") { return URL(fileURLWithPath: given) }
    let places = ["Desktop", "Downloads"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)
    }
    for place in places {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: place, includingPropertiesForKeys: nil)) ?? []
        if let hit = contents.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return (name.hasSuffix(".iso") || name.hasSuffix(".cue"))
                && (name.contains("amiga") || name.contains("cucd") || name.contains("scala"))
        }) { return hit }
    }
    return nil
}

func configURL() -> URL {
    workspace.appendingPathComponent("videoboy-amiga.fs-uae")
}

// MARK: - Verbs

func runSetup() {
    print("videoboy-amiga setup\n")
    var missing = 0

    if FSUAEInstallation.isInstalled() {
        print("  emulator   FS-UAE at \(FSUAEInstallation.applicationPath)")
    } else {
        print("  emulator   MISSING — \(FSUAEInstallation.installationHint)")
        missing += 1
    }

    let disc = findDiscImage()
    if let disc {
        print("  media      \(disc.lastPathComponent)")
    } else {
        print("  media      none found in ~/Desktop or ~/Downloads")
    }

    let firmware = FSUAEInstallation.firmware(kickstartPath: option("kickstart"))
    switch firmware {
    case .kickstart(let path):
        print("  firmware   Kickstart at \(path)")
    case .aros:
        print("  firmware   AROS (built into FS-UAE) — no Kickstart needed")
    }
    if let note = firmware.note { print("             \(note)") }

    // Assemble a bootable drive from the disc. AROS supplies the ROM; a machine still
    // needs AmigaDOS, ARexx and the software on a drive it can boot.
    let systemDrive = workspace.appendingPathComponent("System")
    let installer = AmigaSystemInstaller(destination: systemDrive)
    var volumeName = "Workbench"

    if let disc {
        do {
            let mounted = try DiscImage(path: disc).mount()
            volumeName = mounted.lastPathComponent
            if installer.isInstalled && !arguments.contains("--reinstall") {
                print("  system     already built at \(systemDrive.path)")
                print("             (--reinstall rebuilds it)")
            } else {
                print("  system     building from \(mounted.lastPathComponent)...")
                let result = try installer.install(from: mounted) { drawer in
                    print("               \(drawer)")
                }
                print("  system     \(result.summary)")
            }
        } catch {
            print("  system     FAILED: \(error.localizedDescription)")
            missing += 1
        }
    } else {
        print("  system     no disc to build from")
        missing += 1
    }

    var configuration = FSUAEConfiguration(
        program: program, firmware: firmware,
        sharedDrawer: sharedDrawer,
        systemDrive: installer.isInstalled ? systemDrive : nil)
    configuration.systemVolumeName = volumeName
    configuration.windowTitle = "Videoboy Amiga"

    do {
        let written = try configuration.write(to: workspace)
        // Read back off the config rather than restating it here: a readout that
        // says NTSC while the file says PAL is worse than no readout.
        let standard = written.path.isEmpty ? "" : ""
        _ = standard
        print("\n  machine    \(configuration.amigaModel), "
            + "\(configuration.fastMemory)MB fast, "
            + (configuration.text.contains("ntsc_mode = 1") ? "NTSC" : "PAL"))
        print("  drawer     \(sharedDrawer.path)")
        print("  config     \(written.path)")
        let contents = AmigaSideScripts.drawerContents()
        print("  amiga side \(contents.keys.sorted().joined(separator: ", "))")
    } catch {
        print("\n  FAILED to write the workspace: \(error.localizedDescription)")
        exit(1)
    }

    print("")
    if missing == 0 {
        print("Ready. `videoboy-amiga launch` starts it.")
    } else {
        print("\(missing) thing(s) still needed — see above.")
        exit(1)
    }
}

func runLaunch() {
    guard FSUAEInstallation.isInstalled() else {
        print(FSUAEInstallation.installationHint)
        exit(1)
    }
    guard FileManager.default.fileExists(atPath: configURL().path) else {
        print("No config yet. Run `videoboy-amiga setup` first.")
        exit(1)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: FSUAEInstallation.executablePath)
    process.arguments = [configURL().path]
    do {
        try process.run()
        print("FS-UAE started (pid \(process.processIdentifier)).")
        print("Commands posted to \(sharedDrawer.path)/cmd will reach it once the")
        print("machine has booted and VBLink.rexx is running.")
    } catch {
        print("could not start FS-UAE: \(error.localizedDescription)")
        exit(1)
    }
}

/// Posts raw lines, bypassing the panel — for testing one link at a time.
func runSend(_ lines: [String]) {
    guard !lines.isEmpty else { usage() }
    do {
        let transport = try SharedDrawerTransport(root: sharedDrawer)
        let bridge = AmigaCommandBridge(transport: transport)
        bridge.sendImmediately(lines.map { TitlerCommand.raw($0) })
        // sendImmediately is asynchronous by design — it must never block a caller on
        // the UI thread. A command-line tool has to wait for it, so it does.
        Thread.sleep(forTimeInterval: 0.2)
        print("posted \(lines.count) line(s) to \(transport.commandsDirectory.path)")
        for line in lines { print("  \(line)") }
    } catch {
        print("could not reach the drawer: \(error.localizedDescription)")
        exit(1)
    }
}

/// Moves a panel control and posts whatever Scala lines it produces.
///
/// The end-to-end check of the whole idea: a number in, real commands out, delivered.
func runPanel(_ rest: [String]) {
    guard rest.count >= 2,
          let function = TitlerFunction(rawValue: rest[0]),
          let value = Double(rest[1]) else {
        print("controls: " + TitlerFunction.allCases.map(\.rawValue).joined(separator: ", "))
        exit(2)
    }
    let panel = ScalaTitlerPanel()
    let commands = panel.set(function, to: value)
    guard !commands.isEmpty else {
        print("\(function.rawValue) produced nothing: "
            + (panel.unavailableReason(for: function) ?? "unknown reason"))
        exit(1)
    }
    print("\(function.rawValue) = \(value)  ->  \(panel.readout(for: function))")
    for command in commands { print("  \(command.line)    ; \(command.explanation)") }
    runSend(commands.map(\.line))
}

func runStatus() {
    let drawer = sharedDrawer.appendingPathComponent("cmd")
    let acks = sharedDrawer.appendingPathComponent("ack")
    func count(_ url: URL, suffix: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(suffix) }.count
    }
    let waiting = count(drawer, suffix: ".vbc")
    let answered = count(acks, suffix: ".ack")
    print("workspace   \(workspace.path)")
    print("emulator    \(FSUAEInstallation.isInstalled() ? "installed" : "MISSING")")
    print("unread      \(waiting) command file(s) sitting in cmd/")
    print("answered    \(answered) acknowledgement(s) in ack/")
    if waiting > 0 && answered == 0 {
        print("\nNothing has been picked up. Either the machine has not booted, or")
        print("VBLink.rexx is not running inside it.")
    } else if answered > 0 {
        print("\nThe listener is alive — commands are getting through.")
    }
}

func runVocabulary() {
    print("Scala MM300, read off CU Amiga Super CD-ROM 19\n")
    print("port      \(ScalaLingo.portName)")
    print("wipes     \(ScalaLingo.wipes.count): "
        + ScalaLingo.wipes.prefix(12).joined(separator: " ") + " …")
    print("dirs      " + ScalaLingo.directions.joined(separator: " "))
    print("fonts     \(ScalaLingo.fonts.count): " + ScalaLingo.fonts.joined(separator: " "))
    print("speed     \(ScalaLingo.speedRange.lowerBound)…\(ScalaLingo.speedRange.upperBound)"
        + "  (lower is faster)")
    print("type size \(ScalaLingo.fontSizeRange.lowerBound)…"
        + "\(ScalaLingo.fontSizeRange.upperBound)pt")
    print("\ncontrols, and the Scala function each one reaches:")
    let panel = ScalaTitlerPanel()
    for control in ScalaTitlerPanel.controls {
        let sample = panel.set(control.function, to: 0.5).first?.line
            ?? (panel.unavailableReason(for: control.function) ?? "—")
        print(String(format: "  %-9s %-16s %@", (control.name as NSString).utf8String!,
                     (control.function.rawValue as NSString).utf8String!, sample))
    }
}

switch verb {
case "setup": runSetup()
case "launch": runLaunch()
case "send": runSend(Array(arguments.dropFirst()))
case "panel": runPanel(Array(arguments.dropFirst()))
case "status": runStatus()
case "vocabulary": runVocabulary()
default: usage()
}
