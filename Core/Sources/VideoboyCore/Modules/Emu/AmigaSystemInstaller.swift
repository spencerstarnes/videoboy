//
//  AmigaSystemInstaller.swift — building a bootable Amiga out of the user's own disc.
//
//  Purpose : AROS supplies a Kickstart, but Kickstart is only the ROM. A machine still
//            needs AmigaDOS, ARexx and the software itself on a drive it can boot. This
//            assembles one from the media the person already owns.
//  Inputs  : a mounted disc (or any directory laid out like an Amiga system volume).
//  Outputs : a writable system drive in the app's own support directory, with a
//            Startup-Sequence that brings up ARexx, the command listener and the
//            program.
//  Connects: FSUAEConfiguration (which mounts it), AmigaSideScripts (whose listener the
//            startup runs), the EMU panel's SET UP button.
//  Extend  : a different disc layout is a different `Layout`. Do not special-case a
//            particular disc here — if it has C/, L/, Libs/ and S/, it works.
//
//  ── WHY COPY AT ALL, RATHER THAN MOUNT THE DISC DIRECTLY ────────────────────────
//
//  Three reasons, in order of how much they bite.
//
//  WRITABILITY. A mounted ISO is read only. An Amiga boot writes — ENV:, T:, its own
//  preferences — and a system that cannot write is a system that fails in obscure
//  places rather than at the start.
//
//  SIZE. The disc is 620MB; the parts a machine needs to boot and run the titler come
//  to about 37MB. Copying the whole thing would be slow and pointless.
//
//  THE STARTUP-SEQUENCE. The disc's own is written for a CD32 and does a great deal of
//  work — PicBoot, MountENV, monitor detection — that is wrong for this machine. Ours
//  replaces it, and replacing a file requires a copy.
//
//  Nothing is bundled and nothing is downloaded: this is the person's disc, copied into
//  the person's own Application Support directory, and deleting that directory undoes
//  all of it.
//

import Foundation

/// Assembles a bootable Amiga system drive from a disc.
public struct AmigaSystemInstaller: Sendable {

    /// The drawers copied from the disc, and why each one is needed.
    ///
    /// Listed rather than "copy everything" because the difference is 37MB against
    /// 620MB, and because a list is a statement of what the machine actually requires.
    public static let requiredDrawers: [(name: String, reason: String)] = [
        ("C", "AmigaDOS commands — Assign, Copy, Wait, without which no script runs"),
        ("L", "filesystem and port handlers"),
        ("Libs", "shared libraries, including rexxsupport which the listener needs"),
        ("Devs", "devices and monitor definitions"),
        ("S", "startup scripts — ours replaces the disc's"),
        ("Rexxc", "the ARexx commands, RX among them"),
        ("System", "RexxMast, the ARexx daemon"),
        ("Classes", "datatypes, for loading pictures"),
        ("Locale", "language files the OS expects to find"),
        ("Fonts", "typefaces, including the ones the titler titles with"),
        ("Prefs", "the preferences archive the program reads from ENV:"),
        ("Storage", "optional drivers"),
        ("Scala", "the titling software itself")
    ]

    /// What the startup runs to bring the titler up.
    ///
    /// ── THE PLAYER, NOT THE EDITOR ───────────────────────────────────────────────
    ///
    /// Scala ships two programs. ScalaMM is the authoring environment — where a person
    /// builds pages by hand. ScalaMMPlayer is the runtime, and it is the one that OPENS
    /// `rexx_ScalaMM`: the disc's own ARexx example says "Talk to ScalaPlayer" in its
    /// comments, and the port name is in the Player's binary.
    ///
    /// So the Player is what this app drives. It is also better behaved when something
    /// is wrong: it prints its errors to the console, where they can be read, while the
    /// editor puts up a modal requester that sits over the screen being captured.
    ///
    /// `-rexx` is its own flag for opening the port.
    public static let defaultTitlerCommand = "SYS:Scala/ScalaMMPlayer -rexx"

    /// Where the assembled drive goes.
    public let destination: URL
    private let fileManager: FileManager

    public init(destination: URL, fileManager: FileManager = .default) {
        self.destination = destination
        self.fileManager = fileManager
    }

    /// Whether a directory looks like an Amiga system volume worth copying.
    ///
    /// Four drawers, because any disc with all four can boot and anything missing one
    /// of them cannot. Checking for the software as well would reject a perfectly good
    /// Workbench disc.
    public static func looksBootable(_ source: URL, fileManager: FileManager = .default) -> Bool {
        ["C", "L", "Libs", "S"].allSatisfy {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: source.appendingPathComponent($0).path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    /// Whether the drive has already been built.
    public var isInstalled: Bool {
        fileManager.fileExists(
            atPath: destination.appendingPathComponent("S/Startup-Sequence").path)
    }

    /// What happened, in words the panel can show.
    public struct Result: Sendable {
        public let copiedDrawers: [String]
        public let skippedDrawers: [String]
        public let megabytes: Int

        public var summary: String {
            "\(copiedDrawers.count) drawers, \(megabytes)MB"
                + (skippedDrawers.isEmpty
                    ? ""
                    : " — not on the disc: \(skippedDrawers.joined(separator: ", "))")
        }
    }

    /// Copies what is needed and writes the startup script.
    ///
    /// - Parameter progress: called with each drawer's name as it starts, so a long
    ///   copy is not a frozen panel.
    @discardableResult
    public func install(
        from source: URL,
        titlerPath: String = AmigaSystemInstaller.defaultTitlerCommand,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        guard AmigaSystemInstaller.looksBootable(source, fileManager: fileManager) else {
            throw InstallError.notAnAmigaVolume(source.lastPathComponent)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied: [String] = []
        var skipped: [String] = []

        for drawer in AmigaSystemInstaller.requiredDrawers {
            let from = source.appendingPathComponent(drawer.name)
            guard fileManager.fileExists(atPath: from.path) else {
                skipped.append(drawer.name)
                continue
            }
            progress?(drawer.name)
            let to = destination.appendingPathComponent(drawer.name)
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            try fileManager.copyItem(at: from, to: to)
            copied.append(drawer.name)
        }

        // A disc mounts read-only, so everything copied off one arrives read-only. An
        // Amiga that cannot write to its own system drive fails in obscure places
        // rather than at the start, which is much harder to diagnose.
        try makeWritable(destination)

        try writeStartupSequence(titlerPath: titlerPath)

        let bytes = (try? fileManager.allocatedSizeOfDirectory(at: destination)) ?? 0
        let result = Result(
            copiedDrawers: copied, skippedDrawers: skipped,
            megabytes: Int(bytes / 1_048_576))
        Log.info(.titler, "amiga system drive: \(result.summary)")
        return result
    }

    /// The Startup-Sequence the machine boots.
    ///
    /// Ours, not the disc's. Kept here rather than in `AmigaSideScripts` because it is
    /// specific to a drive we assembled and knows where we put things; the listener is
    /// generic and does not.
    public func startupSequence(
        titlerPath: String = AmigaSystemInstaller.defaultTitlerCommand
    ) -> String {
        AmigaSideScripts.asciiFolded("""
        ; Videoboy boot. GENERATED by AmigaSystemInstaller.swift.
        ;
        ; Replaces the disc's own Startup-Sequence, which is written for a CD32 and
        ; does a great deal of work this machine neither needs nor has hardware for.

        C:SetPatch QUIET
        C:MakeDir >NIL: RAM:T RAM:Clipboards RAM:ENV RAM:ENV/Sys
        Assign T: RAM:T
        Assign CLIPS: RAM:Clipboards
        Assign ENV: RAM:ENV
        Assign REXX: SYS:S
        Assign FONTS: SYS:Fonts
        FailAt 21

        ; The titler keeps its own devices and libraries in its System drawer, and
        ; OpenDevice() searches DEVS: — so that drawer has to be ON DEVS: or they are
        ; invisible to it.
        IF EXISTS SYS:Scala
            Assign SCALA: SYS:Scala
            ; The titler's modules must be where exec LOOKS FOR THEM BY NAME, and the two
            ; halves go to different places. Read out of the binaries themselves:
            ;
            ;   scalamm.gfx  romtag type NT_DEVICE,  name "scalamm.gfx"  -> DEVS:
            ;   scalamm.sys  romtag type NT_LIBRARY, name "scalamm.sys"  -> LIBS:
            ;
            ; An ADD assign to the drawer they live in is NOT enough and was actively
            ; wrong: exec asks for "scalamm.gfx", and DEVS: assigned to .../System
            ; resolved the relative form to System/System/scalamm.gfx. They are copied
            ; in flat, by name.
            C:Copy >NIL: SYS:Scala/System/#?.gfx SYS:Devs QUIET
            C:Copy >NIL: SYS:Scala/System/#?.sys SYS:Libs QUIET
            C:Copy >NIL: SYS:Scala/System/#? SYS:Devs QUIET
            C:Copy >NIL: SYS:Scala/System/#? SYS:Libs QUIET
        ENDIF

        ; Programs read their preferences from ENV:, not from where they were installed.
        IF EXISTS SYS:Prefs/Env-Archive
            C:Copy >NIL: SYS:Prefs/Env-Archive ENV: ALL QUIET
        ENDIF

        BindDrivers

        ; Order matters below. ARexx has to be up before anything can open a port, and
        ; the listener has to be last so it never forwards into a port that is not there
        ; yet.
        echo "Videoboy: starting ARexx"
        Run >NIL: SYS:System/RexxMast
        C:Wait 4

        ; >NIL: on purpose. Redirecting to a file in the shared drawer looked like a
        ; free diagnostic channel and is not: ARexx buffers its console output, so the
        ; file stays empty until the script exits — which for a watch loop is never.
        ; The listener writes its own heartbeat into VB:ack/link.status instead.
        echo "Videoboy: starting the command listener"
        Run >NIL: SYS:Rexxc/RX VB:VBLink.rexx

        echo "Videoboy: starting the titler"
        \(titlerPath.isEmpty ? "" : "CD SYS:Scala")
        \(titlerPath.isEmpty ? "" : titlerPath)
        """)
    }

    private func writeStartupSequence(titlerPath: String) throws {
        let directory = destination.appendingPathComponent("S")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep the disc's own, in case anyone wants to see what it did.
        let target = directory.appendingPathComponent("Startup-Sequence")
        let backup = directory.appendingPathComponent("Startup-Sequence.original")
        if fileManager.fileExists(atPath: target.path),
           !fileManager.fileExists(atPath: backup.path) {
            try? fileManager.copyItem(at: target, to: backup)
        }
        try startupSequence(titlerPath: titlerPath)
            .write(to: target, atomically: true, encoding: .isoLatin1)
    }

    private func makeWritable(_ root: URL) throws {
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// What the titler can reach on the installed drive, for the panel's choice
    /// controls.
    ///
    /// Read from the DRIVE rather than hard-coded, because these are whatever the
    /// person's disc happens to carry — and a fader that picks between names that are
    /// not there is the exact failure the control set exists to prevent.
    public struct TitlerAssets: Sendable {
        /// Background pictures, as Amiga paths the machine can open.
        public let backdrops: [String]
        /// Page names, from the EVENT lines of the scripts on the drive.
        public let pageNames: [String]
        /// Graphics that can be placed and scaled, from the Symbols drawer.
        public let symbols: [String]
        /// The typefaces on the drive, each with the sizes it actually exists at.
        public let fonts: [ScalaFont]
    }

    /// Every typeface in a Fonts drawer, with the sizes it exists at.
    ///
    /// ── WHY THE SIZES HAVE TO BE READ OFF THE DISC ──────────────────────────────
    ///
    /// Amiga fonts are BITMAPS. A face exists at a handful of fixed sizes and at no
    /// others, and the set differs per face: Franklin is 18, 23, 36 and 72; Didot is 28
    /// and 56; GillN is 58 and nothing else. An `X.font` file sits beside a drawer named
    /// `X`, and that drawer's entries ARE the sizes.
    ///
    /// Asking Scala for a size a face does not have is not a cosmetic mistake. It does
    /// not fall back to the nearest — it drops its screen, and the machine's output
    /// reverts to the AmigaDOS console. See
    /// selfqa/out/emu-probe/03-font-franklin-44-not-on-disc.png. Offering a continuous
    /// size fader over a bitmap font is therefore a way to put a boot prompt on air.
    private static func fonts(
        in directory: URL, fileManager: FileManager
    ) -> [ScalaFont] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var found: [ScalaFont] = []

        for entry in entries.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where entry.lowercased().hasSuffix(".font") {
            let face = String(entry.dropLast(5))
            // The sizes are the names of the files in the face's own drawer.
            let sizes = ((try? fileManager.contentsOfDirectory(
                atPath: directory.appendingPathComponent(face).path)) ?? [])
                .compactMap(Int.init)
                .sorted()
            guard !sizes.isEmpty else { continue }
            found.append(ScalaFont(name: face, sizes: sizes))
        }
        return found
    }

    /// Every picture in a drawer, as Amiga paths.
    ///
    /// Amiga paths because that is what the MACHINE will be asked to open — a host path
    /// is meaningless on the other side of the wire. Sub-drawers are walked one level,
    /// because the disc groups its graphics that way.
    private static func pictures(
        in directory: URL, volumeName: String, amigaPrefix: String,
        fileManager: FileManager
    ) -> [String] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var found: [String] = []
        for entry in entries.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard !entry.hasSuffix(".info"), !entry.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(entry)
            guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                found += pictures(
                    in: path, volumeName: volumeName,
                    amigaPrefix: "\(amigaPrefix)/\(entry)", fileManager: fileManager)
            } else {
                found.append("\(volumeName):\(amigaPrefix)/\(entry)")
            }
        }
        return found
    }

    /// Scans the installed drive for what the panel can offer.
    /// - Parameter fontDrawers: where to look for typefaces, in order of preference.
    ///   The installed drive is NOT one of them by default: the fonts are not copied
    ///   in — they stay on the disc, which is why the boot assigns `Fonts:` to
    ///   `SCALA-MM400:Scala/Fonts` rather than to `SYS:`. Scanning the workspace found
    ///   nothing, so the panel offered no sizes and kept its size menu shut for ever.
    public func titlerAssets(
        volumeName: String, fontDrawers: [URL] = [],
        fileManager: FileManager = .default
    ) -> TitlerAssets {
        let scala = destination.appendingPathComponent("Scala")

        // Backgrounds. Amiga paths, because that is what the machine will be asked to
        // open — the host path is meaningless on the other side of the wire.
        let backdrops = Self.pictures(
            in: scala.appendingPathComponent("Backgrounds"), volumeName: volumeName,
            amigaPrefix: "Scala/Backgrounds", fileManager: fileManager)

        // Page names. Scala's pages are named EVENTs, so the names come out of the
        // scripts themselves; there is nothing else that knows them.
        var pages: [String] = []
        let scriptsDirectory = scala.appendingPathComponent("Scripts")
        let scripts = ((try? fileManager.contentsOfDirectory(
            atPath: scriptsDirectory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".script") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for script in scripts {
            let url = scriptsDirectory.appendingPathComponent(script)
            guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.uppercased().hasPrefix("EVENT ") else { continue }
                var name = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !name.isEmpty, name.allSatisfy(\.isASCII) else { continue }
                if !pages.contains(name) { pages.append(name) }
            }
        }

        // Symbols: the graphics the scale control scales. Without at least one, that
        // control is permanently greyed, which is a fader that can never do anything.
        let symbolsDirectory = scala.appendingPathComponent("Symbols")
        let symbols = Self.pictures(
            in: symbolsDirectory, volumeName: volumeName,
            amigaPrefix: "Scala/Symbols", fileManager: fileManager)

        // First drawer that actually has faces in it wins. The installed drive is
        // tried last, because it is the one that usually does not have them.
        let candidates = fontDrawers + [scala.appendingPathComponent("Fonts")]
        let fonts = candidates
            .lazy
            .map { Self.fonts(in: $0, fileManager: fileManager) }
            .first { !$0.isEmpty } ?? []

        Log.info(.titler, "titler assets: \(backdrops.count) backdrops, "
            + "\(pages.count) pages, \(symbols.count) symbols, \(fonts.count) fonts")
        return TitlerAssets(
            backdrops: backdrops, pageNames: pages, symbols: symbols, fonts: fonts)
    }

    public enum InstallError: LocalizedError {
        case notAnAmigaVolume(String)

        public var errorDescription: String? {
            switch self {
            case .notAnAmigaVolume(let name):
                return "\(name) does not look like an Amiga system disc — it needs C, "
                    + "L, Libs and S drawers at its top level. Mount the disc image "
                    + "first, then point at the mounted volume."
            }
        }
    }
}

extension FileManager {
    /// Roughly how large a directory is. Only used for a readout, so an estimate is
    /// fine and walking it twice for accuracy is not.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var total: UInt64 = 0
        guard let walker = enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += UInt64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
