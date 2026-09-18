//
//  FSUAEConfiguration.swift — the setup automation, as a config file.
//
//  Purpose : Turn "run Scala MM300 on an accelerated A1200, with a drawer I can post
//            commands into, at NTSC, in a window I can capture" into the config file
//            FS-UAE actually reads. This is the "script to automate its SETUP" — a
//            generated file rather than a wizard, because a file can be diffed, checked
//            into a template, and TESTED without launching anything.
//  Inputs  : a `TitlerProgram`, the media paths, and the shared drawer.
//  Outputs : the text of a `.fs-uae` config.
//  Connects: EmulatedTitler (the machine profile), AmigaCommandBridge (the drawer),
//            FSUAEHost in the app (which launches it), scripts/setup-amiga.sh.
//  Extend  : a new option is a line in `settings`. Keep them in the enum — an option
//            written as a raw string somewhere else is one nobody will find again.
//
//  ── WHY FS-UAE AND NOT A LIBRETRO CORE ──────────────────────────────────────────
//
//  The plan was a libretro Amiga core. Two things changed it, and both are good news.
//
//  FS-UAE IS A SEPARATE APPLICATION. It is GPL, which is precisely why it must not be
//  linked — and an app we launch and never link is the cleanest possible compliance.
//  A libretro core would sit as a dylib next to a process we control, which is a
//  narrower path to walk.
//
//  FS-UAE SHIPS AROS. Its binary carries "AROS KS ROM (built-in)" — a free, open-source
//  Kickstart replacement. That removes the hard blocker: the machine boots with NO
//  copyrighted ROM at all. A real Kickstart still gives a better machine, and the
//  config asks for one when it is there, but nothing is stopped for want of it.
//

import Foundation

/// A generated FS-UAE configuration.
public struct FSUAEConfiguration: Equatable, Sendable {

    /// Which Kickstart the machine will use.
    public enum Firmware: Equatable, Sendable {
        /// A real Kickstart ROM the person supplied.
        case kickstart(path: String)
        /// FS-UAE's built-in AROS. Free, and good enough to boot — but it is a
        /// REIMPLEMENTATION, and 1990s commercial software is exactly the category most
        /// likely to notice.
        case aros

        /// What to say about it in the panel, honestly.
        public var note: String? {
            switch self {
            case .kickstart: return nil
            case .aros:
                return "Running on AROS, a free Kickstart replacement. The machine "
                    + "boots, but software written for Kickstart 3.x may refuse or "
                    + "misbehave. Supply a Kickstart ROM for the real thing."
            }
        }
    }

    public var program: TitlerProgram
    public var firmware: Firmware
    /// The host directory mounted as the Amiga volume commands arrive through.
    public var sharedDrawer: URL
    /// A CD image, when the software is on one.
    public var cdImage: URL?
    /// A host directory holding an installed Amiga system — see AmigaSystemInstaller.
    public var systemDrive: URL?
    /// What the system drive is called on the Amiga.
    ///
    /// Matters more than it looks. Software stores absolute paths in its preferences —
    /// Scala's config lists `CUCD19:SCALA/BACKGROUNDS/` and friends — so naming the
    /// volume after the disc it came from is what makes those paths resolve instead of
    /// producing a file requester on every load.
    public var systemVolumeName = "Workbench"
    /// Floppy images, in drive order.
    public var floppies: [URL] = []
    /// The window FS-UAE opens, which is also what gets captured.
    public var windowSize: (width: Int, height: Int) = (720, 540)
    /// The window title, which is how the capture finds it.
    public var windowTitle: String = "Videoboy Amiga"

    /// Restore the saved state instead of booting from cold.
    ///
    /// ── WHY A SAVE STATE IS THE WHOLE ANSWER HERE ───────────────────────────────
    ///
    /// Driving a boot by timed keystrokes is fragile in a way that gets worse the
    /// longer the boot is: a disc that loads a second slower puts every later step in
    /// the wrong place, and Scala is the slowest of these to come up because it is a
    /// whole authoring environment rather than a titler.
    ///
    /// A save state sidesteps all of it. Boot ONCE by hand, get the machine exactly
    /// where you want it — software loaded, script open, sitting on the page you will
    /// title from — and save. Every start after that lands there in about a second,
    /// identically, with no sequencing to go wrong.
    public var loadsSavedState: Bool = false

    /// Where states are kept.
    ///
    /// Inside the app's own workspace rather than FS-UAE's shared folder, so a state is
    /// part of THIS machine's setup and goes away with it. A state saved against one
    /// configuration and restored into a different one is a crash.
    public var saveStatesDirectory: URL?

    public init(
        program: TitlerProgram, firmware: Firmware, sharedDrawer: URL,
        cdImage: URL? = nil, systemDrive: URL? = nil, floppies: [URL] = []
    ) {
        self.program = program
        self.firmware = firmware
        self.sharedDrawer = sharedDrawer
        self.cdImage = cdImage
        self.systemDrive = systemDrive
        self.floppies = floppies
    }

    public static func == (lhs: FSUAEConfiguration, rhs: FSUAEConfiguration) -> Bool {
        lhs.text == rhs.text
    }

    /// The model to ask FS-UAE for.
    ///
    /// AROS is an A500-era ROM replacement; asking it to be an AGA A1200 is asking for
    /// a machine that will not come up. So WITHOUT a real Kickstart the model steps
    /// down to what AROS can actually be, and the panel says so rather than showing an
    /// A1200 that is secretly an A500.
    public var amigaModel: String {
        switch firmware {
        case .aros:
            // AROS is described as an A500-era replacement, but FS-UAE's build comes
            // up as an A1200 and boots a disc with it — TRIED, not assumed. So the
            // requested machine is honoured, and the note below still says what is
            // underneath.
            return program.machine == .amiga500 ? "A500" : "A1200"
        case .kickstart:
            switch program.machine {
            case .amiga500: return "A500"
            case .amiga1200, .amiga1200Vampire: return "A1200"
            }
        }
    }

    /// Fast RAM in megabytes.
    ///
    /// The Vampire profile asks for 64MB, which is more than a real A1200 Zorro bus
    /// offers — FS-UAE takes it, and Scala is happier with room than with accuracy
    /// here. A500 + AROS gets none, because autoconfig RAM on an AROS A500 is the
    /// fastest way to a machine that does not boot.
    public var fastMemory: Int {
        switch firmware {
        case .aros:
            // Modest rather than none. A large autoconfig space on AROS is the fastest
            // way to a machine that will not boot, and 8MB is enough for the titler.
            return program.machine == .amiga500 ? 0 : 8
        case .kickstart:
            switch program.machine {
            case .amiga500: return 0
            case .amiga1200: return 8
            case .amiga1200Vampire: return 64
            }
        }
    }

    /// The config file's text.
    ///
    /// Written in the order a person would want to read it — what machine, what is in
    /// it, what is plugged in, what the window does — rather than alphabetically.
    public var text: String {
        var lines: [String] = [
            "# Videoboy — generated by FSUAEConfiguration.swift. Regenerated on every",
            "# launch, so edits here are lost; change the panel or the machine profile.",
            "#",
            "# Program : \(program.name)",
            "# Machine : \(program.machine.displayName)",
            "# Firmware: \(firmwareDescription)",
            "",
            "[fs-uae]",
            "",
            "# ── The machine ──",
            "amiga_model = \(amigaModel)"
        ]

        if case .kickstart(let path) = firmware {
            lines.append("kickstart_file = \(path)")
        } else {
            lines.append("# No kickstart_file: FS-UAE falls back to its built-in AROS.")
        }

        lines += [
            "chip_memory = 2048",
            "fast_memory = \(fastMemory)",
            "",
            "# ── Video ──",
            "# PAL. The output chain is 480i NTSC throughout and every instinct says to",
            "# match it here — but this software is PAL-authored (640x512, and its own",
            "# preferences ask for pal.monitor), so an NTSC machine crops its pages. The",
            "# capture resamples into the project's 720x480 either way, exactly as it",
            "# does for every other source, so the conversion costs nothing extra here",
            "# and running the machine as its software expects costs a great deal.",
            "ntsc_mode = 0",
            "",
            "# ── Drives ──",
            "# The BOOT drive goes first. FS-UAE boots the lowest-numbered drive, so a",
            "# shared drawer in slot 0 gives a machine that comes up with no operating",
            "# system and no explanation."
        ]

        var slot = 0
        if let systemDrive {
            lines.append("hard_drive_\(slot) = \(systemDrive.path)")
            lines.append("hard_drive_\(slot)_label = \(systemVolumeName)")
            slot += 1
        } else {
            lines.append("# No system drive: AROS will boot to a screen with nothing on it.")
            lines.append("# Run the installer against a mounted Amiga disc first.")
        }

        // The shared drawer: the host writes command files into its cmd/ sub-drawer and
        // the ARexx listener inside the machine forwards them.
        lines.append("hard_drive_\(slot) = \(sharedDrawer.path)")
        lines.append("hard_drive_\(slot)_label = \(AmigaSideScripts.volumeName)")
        if let cdImage {
            lines.append("cdrom_drive_0 = \(cdImage.path)")
        }
        for (index, floppy) in floppies.prefix(4).enumerated() {
            lines.append("floppy_drive_\(index) = \(floppy.path)")
        }

        lines += [
            "",
            "# ── The window ──",
            "# Windowed, fixed size, no border, and titled: the title is how the frame",
            "# capture finds this window among everything else on the desktop.",
            "fullscreen = 0",
            "window_width = \(windowSize.width)",
            "window_height = \(windowSize.height)",
            "window_resizable = 0",
            "window_border = 0",
            "title = \(windowTitle)",
            "",
            "# ── Save states ──",
            "# F5 saves, F6 restores — INSIDE the emulator's window, pressed by hand.",
            "# Synthesising those keys from outside would need Accessibility permission",
            "# to send events to another application, which is a large thing to ask for",
            "# a convenience. Two keys the person presses themselves need nothing.",
            "keyboard_key_f5 = action_save_state_1",
            "keyboard_key_f6 = action_load_state_1"
        ]

        if let saveStatesDirectory {
            lines.append("save_states_dir = \(saveStatesDirectory.path)")
        }
        if loadsSavedState {
            // Straight to the saved state rather than through a cold boot.
            lines.append("load_state = 1")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private var firmwareDescription: String {
        switch firmware {
        case .kickstart(let path): "Kickstart at \(path)"
        case .aros: "AROS (built into FS-UAE)"
        }
    }

    /// Writes the config and the Amiga-side scripts, and returns the config's path.
    ///
    /// Both together, because a config that mounts a drawer with no listener in it
    /// produces a machine that boots and then ignores everything — which looks exactly
    /// like a bug in this app.
    @discardableResult
    public func write(
        to directory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedDrawer, withIntermediateDirectories: true)

        let scalaPath = cdImage != nil ? "CD0:Scala/ScalaMM" : "Work:Scala/ScalaMM"
        for (name, body) in AmigaSideScripts.drawerContents(scalaPath: scalaPath) {
            try body.write(
                to: sharedDrawer.appendingPathComponent(name),
                atomically: true, encoding: .isoLatin1)
        }

        let configURL = directory.appendingPathComponent("videoboy-amiga.fs-uae")
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        Log.info(.titler, "wrote FS-UAE config to \(configURL.path)")
        return configURL
    }
}

/// The same machine, written as an Amiberry (WinUAE-style) configuration.
///
/// ── WHY THERE ARE TWO EMITTERS ──────────────────────────────────────────────────
///
/// FS-UAE got this working first and its config is the simpler of the two, so it stays.
/// Amiberry is the one that actually matters, for three reasons found by running both:
///
///   1. IT HAS THE SCALA DONGLE. Scala MM300 is copy-protected by a parallel-port
///      dongle, and "Can't open device: scalamm.gfx" is what that protection looks like
///      when it fails. FS-UAE 3.2's core knows eight dongles and Scala is not among
///      them; Amiberry's WinUAE 4.x core has `scala red` and `scala green`.
///   2. ITS AROS IS TEN YEARS NEWER — 2025 against 2015 — and this software is old
///      enough to notice every difference.
///   3. IT TAKES A SAVE STATE ON THE COMMAND LINE, which is the whole answer to a slow
///      boot: land in the right place in a second, identically, every time.
///
/// Honest caveat, because it was tested: the dongle option alone does NOT make MM300
/// run under AROS. It is necessary and not sufficient — see docs/BLOCKED.md.
public struct AmiberryConfiguration: Sendable {

    public var program: TitlerProgram
    public var firmware: FSUAEConfiguration.Firmware
    public var sharedDrawer: URL
    public var systemDrive: URL?
    public var systemVolumeName: String
    /// A state to restore instead of booting cold.
    public var stateFile: URL?
    public var windowSize: (width: Int, height: Int)

    public init(
        program: TitlerProgram, firmware: FSUAEConfiguration.Firmware,
        sharedDrawer: URL, systemDrive: URL? = nil,
        systemVolumeName: String = "Workbench", stateFile: URL? = nil,
        windowSize: (width: Int, height: Int) = (720, 568)
    ) {
        self.program = program
        self.firmware = firmware
        self.sharedDrawer = sharedDrawer
        self.systemDrive = systemDrive
        self.systemVolumeName = systemVolumeName
        self.stateFile = stateFile
        self.windowSize = windowSize
    }

    /// Which dongle the program needs, in the emulator's own words.
    ///
    /// Data on the PROGRAM rather than a constant here, because the next piece of
    /// 1990s software will have its own protection and this is where that difference
    /// belongs.
    public var dongle: String? {
        program.name.hasPrefix("Scala MM3") ? "scala green" : nil
    }

    public var text: String {
        var lines: [String] = [
            "# Videoboy - generated by AmiberryConfiguration.swift.",
            "# Regenerated on every launch; edits here are lost.",
            "config_description=Videoboy \(program.name)",
            ""
        ]

        switch firmware {
        case .kickstart(let path):
            lines.append("kickstart_rom_file=\(path)")
        case .aros:
            // Amiberry's built-in AROS, same idea as FS-UAE's: a machine that boots
            // with no copyrighted ROM at all.
            lines.append("kickstart_rom_file=:AROS")
        }

        // ECS rather than AGA. This software is from 1993 and its graphics engine is
        // an ECS-era display driver; asking a partial AGA implementation for modes it
        // was never written against is a way to fail that looks like something else.
        lines += [
            "cpu_type=68020",
            "cpu_model=68020",
            "chipset=ecs",
            "chipmem_size=4",
            "fastmem_size=8",
            "ntsc=false"
        ]

        if let dongle {
            lines.append("dongle=\(dongle)")
        }

        lines += [
            "gfx_width=\(windowSize.width)",
            "gfx_height=\(windowSize.height)",
            "gfx_fullscreen_amiga=false",
            "use_gui=no"
        ]

        var unit = 0
        if let systemDrive {
            lines.append(
                "uaehf\(unit)=dir,rw,DH\(unit):\(systemVolumeName):\(systemDrive.path),0")
            unit += 1
        }
        lines.append(
            "uaehf\(unit)=dir,rw,DH\(unit):\(AmigaSideScripts.volumeName):\(sharedDrawer.path),0")

        if let stateFile {
            lines.append("statefile=\(stateFile.path)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func write(
        to directory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedDrawer, withIntermediateDirectories: true)

        for (name, body) in AmigaSideScripts.drawerContents() {
            try body.write(
                to: sharedDrawer.appendingPathComponent(name),
                atomically: true, encoding: .isoLatin1)
        }

        let url = directory.appendingPathComponent("videoboy-amiga.uae")
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.info(.titler, "wrote Amiberry config to \(url.path)")
        return url
    }
}

/// Where Amiberry is.
public enum AmiberryInstallation {

    public static let applicationPath = "/Applications/Amiberry.app"

    public static var executablePath: String {
        applicationPath + "/Contents/MacOS/Amiberry"
    }

    public static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: executablePath)
    }

    public static let installationHint =
        "Amiberry is not installed. `brew install amiberry` puts it in /Applications. "
        + "It is GPL, so Videoboy launches it as a separate program and never links it. "
        + "It is preferred over FS-UAE because its core emulates the protection dongle "
        + "Scala MM300 needs, its AROS is a decade newer, and it can restore a save "
        + "state from the command line."
}

/// The saved state for a machine, if there is one.
///
/// A tiny type rather than a path passed around: "is there a state" is asked by the
/// panel, by the launcher and by the config, and three places computing the same
/// filename is three places to get it wrong.
public struct AmigaSaveState: Sendable {

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// FS-UAE writes `.uss` files, one per slot.
    public var files: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "uss" }
    }

    public var exists: Bool { !files.isEmpty }

    /// When the newest state was saved, for the panel's readout.
    public var savedAt: Date? {
        files.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.max()
    }

    /// One line for the panel.
    public var summary: String {
        guard let savedAt else { return "No saved state yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Saved \(formatter.string(from: savedAt))"
    }
}

/// Where FS-UAE is, and whether it is there at all.
public enum FSUAEInstallation {

    /// The usual place a Homebrew cask puts it.
    public static let applicationPath = "/Applications/FS-UAE.app"

    /// The executable inside the bundle.
    public static var executablePath: String {
        applicationPath + "/Contents/MacOS/fs-uae"
    }

    public static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: executablePath)
    }

    /// What to tell someone who does not have it, in words they can act on.
    public static let installationHint =
        "FS-UAE is not installed. `brew install --cask fs-uae-emulator` puts it in "
        + "/Applications. It is GPL, so Videoboy launches it as a separate program and "
        + "never links it."

    /// Whether a real Kickstart is available, and the firmware to use either way.
    ///
    /// Looks only where it is told to. This app does not go hunting across the disk for
    /// copyrighted ROMs, and it certainly does not download one.
    public static func firmware(
        kickstartPath: String?, fileManager: FileManager = .default
    ) -> FSUAEConfiguration.Firmware {
        guard let kickstartPath, fileManager.fileExists(atPath: kickstartPath) else {
            return .aros
        }
        return .kickstart(path: kickstartPath)
    }
}
