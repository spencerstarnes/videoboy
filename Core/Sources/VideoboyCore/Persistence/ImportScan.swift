//
//  ImportScan.swift — what a drop of files and folders turns into, and how an import
//  reports its progress.
//
//  Purpose : Adding a large library froze the app: the folder walk, each poster and
//            each clip's measurement ran on the main thread (audit 09-26 R1–R3). The
//            import is now a background job (App: ImportJob); this is its pure part —
//            the rules for turning dropped URLs into clips, and the progress model the
//            status bar shows — kept in Core so it is unit-tested headlessly.
//  Inputs  : dropped URLs, a target bin.
//  Outputs : `ImportCandidate`s, rejected names, per-folder counts; `ImportProgress`.
//  Connects: ImportJob and ShellController (App), ImageSequenceDecoder, ClipProbe.
//  Extend  : a new playable format is an entry in `playableExtensions`.
//
//  THE RULES (unchanged from the synchronous version they replace):
//    - a folder of photographs is ONE clip (SEQ), never a bin of stills;
//    - any other folder is walked all the way down, to `maximumFolderDepth`, and the
//      folder tree becomes the same tree of bins (BinPath): Shoots/2019/clip.mov lands
//      in the bin "2019" inside the bin "Shoots". (Before 2026-09-28 every folder
//      became a top-level bin named after itself, so the tree was lost and two
//      folders of the same name merged.);
//    - dropped INTO a bin, the tree lands inside that bin;
//    - files handed over with a `root` (Import mode's "Include subfolders") keep
//      the folders between the root and themselves, inside the chosen bin;
//    - anything that is not playable is named in `rejected`, never silently dropped.
//

import Foundation

/// One clip an import will add.
public struct ImportCandidate: Equatable, Sendable {
    public let url: URL
    /// The bin it lands in; nil for the library's top level.
    public let bin: String?
    /// A folder of photographs, played as one clip.
    public let isSequence: Bool
}

public enum ImportScan {

    /// What this build can open. A .dv file plays as ordinary video through
    /// AVFoundation — it has no bitstream effects, but it is still footage.
    public static let playableExtensions: Set<String> = [
        "dv", "mov", "mp4", "m4v", "m2v", "mpg", "mpeg", "ts", "m2t", "m2ts"
    ]

    /// How deep a dropped folder is walked: deep enough for year/shoot/reel filing,
    /// shallow enough that a mis-dropped home folder stops rather than grinding.
    public static let maximumFolderDepth = 4

    /// The result of a walk.
    public struct Result: Equatable {
        public var candidates: [ImportCandidate] = []
        /// Names of dropped FILES that are not playable. (Unplayable files inside a
        /// walked folder are simply not clips, and are not listed.)
        public var rejected: [String] = []
        /// Whether any dropped item was a folder — the status bar's first reason to show.
        public var includesFolder = false
    }

    /// Turns dropped URLs into clips.
    ///
    /// - Parameters:
    ///   - bin: the bin the drop landed on, or nil for the top level.
    ///   - root: for FILES picked from inside one folder: each file goes into the bins
    ///     its folders below `root` make, inside `bin`. Ignored when `bin` is nil (a
    ///     choice of "no bin" is taken at its word).
    ///   - isCancelled: polled between entries.
    ///   - found: called for each clip as it is found (for the flashing name).
    public static func scan(
        _ urls: [URL], intoBin bin: String? = nil, keepingFoldersBelow root: URL? = nil,
        isCancelled: () -> Bool = { false },
        found: (ImportCandidate) -> Void = { _ in }
    ) -> Result {
        var result = Result()
        for url in urls {
            if isCancelled() { break }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                result.includesFolder = true
                if ImageSequenceDecoder.isSequence(url) {
                    let candidate = ImportCandidate(url: url, bin: bin, isSequence: true)
                    result.candidates.append(candidate)
                    found(candidate)
                } else {
                    for candidate in walk(url, depth: 0, isCancelled: isCancelled) {
                        let placed = bin.map {
                            ImportCandidate(url: candidate.url, bin: BinPath.join($0, candidate.bin ?? ""),
                                            isSequence: candidate.isSequence)
                        } ?? candidate
                        result.candidates.append(placed)
                        found(placed)
                    }
                }
                continue
            }
            if playableExtensions.contains(url.pathExtension.lowercased()) {
                var placedBin = bin
                if let bin, let root, let folders = BinPath.relativeFolder(of: url, below: root) {
                    placedBin = BinPath.join(bin, folders)
                }
                let candidate = ImportCandidate(url: url, bin: placedBin, isSequence: false)
                result.candidates.append(candidate)
                found(candidate)
            } else {
                result.rejected.append(url.lastPathComponent)
            }
        }
        return result
    }

    /// Every clip under a folder, each folder a bin inside its parent's bin.
    ///
    /// - Parameter parentBin: the bin path of the folder above; nil for the folder
    ///   that was dropped, whose bin is its own name at the top level.
    public static func walk(_ folder: URL, depth: Int = 0, parentBin: String? = nil,
                            isCancelled: () -> Bool = { false }) -> [ImportCandidate] {
        guard depth <= maximumFolderDepth, !isCancelled() else { return [] }
        if ImageSequenceDecoder.isSequence(folder) {
            return [ImportCandidate(url: folder, bin: nil, isSequence: true)]
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let binName = BinPath.join(parentBin, folder.lastPathComponent)
        var found: [ImportCandidate] = []
        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if isCancelled() { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                found += walk(child, depth: depth + 1, parentBin: binName, isCancelled: isCancelled)
            } else if playableExtensions.contains(child.pathExtension.lowercased()) {
                found.append(ImportCandidate(url: child, bin: binName, isSequence: false))
            }
        }
        // A sequence found further down sits with its neighbours, in this folder's bin.
        return found.map { $0.bin == nil ? ImportCandidate(url: $0.url, bin: binName, isSequence: $0.isSequence) : $0 }
    }
}

/// Where an import has got to — what the status bar shows.
public struct ImportProgress: Equatable, Sendable {

    public enum Stage: Equatable, Sendable {
        /// Moving or copying files to the destination first (Import mode's Move/Copy).
        case transferring
        /// Walking folders; `found` grows.
        case scanning
        /// Measuring clips (length, frame count); `read` grows.
        case reading
        case finished
        case cancelled
    }

    /// A folder in the import and how many clips it holds.
    public struct Folder: Equatable, Sendable {
        public let name: String
        public var count: Int
    }

    public var stage: Stage = .scanning
    /// What the transferring stage is called: "COPYING" or "MOVING".
    public var transferLabel = "COPYING"
    /// Clips found so far.
    public var found = 0
    /// Clips measured so far.
    public var read = 0
    /// Clips actually added (duplicates of what is already in the bin are not).
    public var added = 0
    /// What is being worked on right now, "Reel B/CLIP0042.MOV".
    public var current: String?
    /// Folders in the order met, with their clip counts.
    public var folders: [Folder] = []
    /// The folder `current` is in.
    public var activeFolder: String?
    /// "name — reason" for each clip that could not be read.
    public var unreadable: [String] = []
    /// Dropped files that are not playable.
    public var rejected: [String] = []
    public var includesFolder = false
    /// Seconds since the import started.
    public var elapsed: TimeInterval = 0

    public init() {}

    /// Above this many clips an import shows the status bar even without folders.
    public static let manyClips = 5
    /// An import still running after this long shows the status bar whatever it holds,
    /// so a slow network volume is never silent.
    public static let slowSeconds: TimeInterval = 2

    /// The status bar appears only when the import is big enough to worry about.
    public var showsStatusBar: Bool {
        includesFolder || found > Self.manyClips || elapsed > Self.slowSeconds
    }

    public var isFinished: Bool { stage == .finished || stage == .cancelled }

    /// Counts a clip into its folder's chip.
    public mutating func count(_ candidate: ImportCandidate) {
        found += 1
        let folder = candidate.bin ?? candidate.url.deletingLastPathComponent().lastPathComponent
        if candidate.bin != nil {
            if let index = folders.firstIndex(where: { $0.name == folder }) {
                folders[index].count += 1
            } else {
                folders.append(Folder(name: folder, count: 1))
            }
            activeFolder = folder
        }
        current = candidate.bin.map { "\($0)/\(candidate.url.lastPathComponent)" } ?? candidate.url.lastPathComponent
    }
}
