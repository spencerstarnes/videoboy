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
    /// A hard-disk image or a host directory holding an installed copy.
    public var systemDrive: URL?
    /// Floppy images, in drive order.
    public var floppies: [URL] = []
    /// The window FS-UAE opens, which is also what gets captured.
    public var windowSize: (width: Int, height: Int) = (720, 540)
    /// The window title, which is how the capture finds it.
    public var windowTitle: String = "Videoboy Amiga"

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
            return "A500"
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
        case .aros: return 0
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
            "# NTSC throughout, because this app's whole output chain is 480i NTSC and a",
            "# PAL machine would have to be resampled on the way out.",
            "ntsc_mode = 1",
            "",
            "# ── Drives ──",
            "# DH0 is the shared drawer: the host writes command files into its cmd/",
            "# sub-drawer and an ARexx listener inside the machine forwards them.",
            "hard_drive_0 = \(sharedDrawer.path)",
            "hard_drive_0_label = \(AmigaSideScripts.volumeName)"
        ]

        if let systemDrive {
            lines.append("hard_drive_1 = \(systemDrive.path)")
            lines.append("hard_drive_1_label = Work")
        }
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
            ""
        ]
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
