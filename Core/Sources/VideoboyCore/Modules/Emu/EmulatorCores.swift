//
//  EmulatorCores.swift — the core system, on libretro's model.
//
//  Purpose : Cores are installed, not built in. The app discovers what is present,
//            says what each one can run, and says plainly what is missing — the way a
//            game front-end does.
//  Inputs  : a cores directory on disk, and a folder of user-supplied system files.
//  Outputs : which platforms are runnable right now, and why the others are not.
//  Connects: EmulatedTitler (which asks whether a program can run), the EMU tab.
//  Extend  : a new core is an entry in `known`. Nothing here loads or links anything.
//
//  ── WHY CORES ARE NOT SHIPPED ──────────────────────────────────────────────────
//
//  libretro cores are GPL. This app is distributed, so linking one would put the whole
//  app under the GPL. They therefore run OUT OF PROCESS and are installed by the
//  person using the app, exactly as a game front-end does it — and exactly as
//  CLAUDE.md requires.
//
//  BIOS and ROM files are a separate problem with the same answer: an Amiga Kickstart
//  is copyrighted, so it is supplied by whoever owns it, referenced by path, never
//  bundled and never fetched.
//

import Foundation

/// A core this app knows how to talk to, whether or not it is installed.
public struct EmulatorCore: Equatable, Codable, Sendable, Identifiable {
    public var id: String { fileName }

    /// The library's file name, without an extension: "puae_libretro".
    public let fileName: String
    public let displayName: String
    public let platform: TitlerProgram.Platform
    /// System files this core needs before it can run anything, by file name.
    public let requiredSystemFiles: [String]
    /// Where to get it, as words rather than a link — this app does not download.
    public let whereToGet: String

    public init(
        fileName: String, displayName: String, platform: TitlerProgram.Platform,
        requiredSystemFiles: [String], whereToGet: String
    ) {
        self.fileName = fileName
        self.displayName = displayName
        self.platform = platform
        self.requiredSystemFiles = requiredSystemFiles
        self.whereToGet = whereToGet
    }
}

/// Whether a core can actually run, and what is stopping it.
public struct CoreStatus: Equatable, Sendable {
    public let core: EmulatorCore
    public let isInstalled: Bool
    /// System files the core needs that are not present.
    public let missingSystemFiles: [String]

    public var isRunnable: Bool { isInstalled && missingSystemFiles.isEmpty }

    /// One line for the panel, saying what to do rather than only what is wrong.
    public var summary: String {
        if !isInstalled {
            return "\(core.displayName) is not installed — put \(core.fileName) in the cores folder"
        }
        if !missingSystemFiles.isEmpty {
            return "\(core.displayName) needs \(missingSystemFiles.joined(separator: ", "))"
        }
        return "\(core.displayName) is ready"
    }
}

/// Finds what is installed.
public struct CoreLibrary: Sendable {

    /// The cores this app has recipes for. Named only — none are included.
    public static let known: [EmulatorCore] = [
        EmulatorCore(
            fileName: "puae_libretro",
            displayName: "PUAE (Amiga)",
            platform: .amiga,
            requiredSystemFiles: ["kick34005.A500.rom"],
            whereToGet: "Install through RetroArch's core downloader, or build from "
                + "the libretro-uae source. The Kickstart ROM must come from an Amiga "
                + "you own, or from Cloanto's licensed Amiga Forever."
        ),
        EmulatorCore(
            fileName: "hatari_libretro",
            displayName: "Hatari (Atari ST)",
            platform: .atariST,
            requiredSystemFiles: ["tos.img"],
            whereToGet: "RetroArch's core downloader. TOS is copyrighted and supplied "
                + "by whoever owns it."
        ),
        EmulatorCore(
            fileName: "dosbox_pure_libretro",
            displayName: "DOSBox Pure",
            platform: .dos,
            requiredSystemFiles: [],
            whereToGet: "RetroArch's core downloader. Needs no system files."
        )
    ]

    /// Where cores are looked for, and where system files are looked for.
    public let coresDirectory: URL
    public let systemDirectory: URL

    public init(coresDirectory: URL, systemDirectory: URL) {
        self.coresDirectory = coresDirectory
        self.systemDirectory = systemDirectory
    }

    /// The status of every known core.
    public func status(fileManager: FileManager = .default) -> [CoreStatus] {
        CoreLibrary.known.map { core in
            let installed = CoreLibrary.coreExtensions.contains { ext in
                fileManager.fileExists(
                    atPath: coresDirectory.appendingPathComponent("\(core.fileName).\(ext)").path)
            }
            let missing = core.requiredSystemFiles.filter { name in
                !fileManager.fileExists(
                    atPath: systemDirectory.appendingPathComponent(name).path)
            }
            return CoreStatus(core: core, isInstalled: installed, missingSystemFiles: missing)
        }
    }

    /// Extensions a core library can have. `.dylib` on macOS; the others are accepted
    /// because cores are often copied across from another machine's RetroArch folder
    /// and refusing them on the file name alone would be unhelpful.
    static let coreExtensions = ["dylib", "so"]

    /// Whether a given program could run right now.
    public func canRun(_ program: TitlerProgram, fileManager: FileManager = .default) -> Bool {
        status(fileManager: fileManager)
            .first { $0.core.platform == program.platform }?
            .isRunnable ?? false
    }

    /// Why a program cannot run, in words a person can act on.
    public func blockedReason(
        for program: TitlerProgram, fileManager: FileManager = .default
    ) -> String? {
        guard let status = status(fileManager: fileManager)
            .first(where: { $0.core.platform == program.platform }) else {
            return "No core for \(program.platform.displayName)"
        }
        return status.isRunnable ? nil : status.summary
    }
}
