//
//  ISFImporter.swift — copying ISF files into Videoboy's own library (SPEC 8).
//
//  Purpose : Import means COPY. A module the operator imports is copied into
//            `ISFLibrary.userFolder`, together with its `.vs` partner and any images
//            its header imports, so it keeps working after the original is moved,
//            renamed, deleted or lost with an external drive. Removing moves the copy
//            to the Trash (recoverable), never deletes it outright.
//  Inputs  : file and folder URLs (a folder is walked for every `.fs` inside it).
//  Outputs : the copied files, and an `ISFImportReport` saying what became of each
//            one — imported (under which name), already there, or skipped and why.
//  Connects: ISFLibrary (the folder, and the scan that lists the result), ISFDocument
//            (a file must parse as ISF to be imported), the Preferences ISF pane
//            (the + / − buttons that call this).
//  Extend  : a new kind of companion file (e.g. a thumbnail) is one more copy in
//            `importOne`, next to the `.vs` and images.
//
//  Synchronous file I/O. Callers run it OFF the main thread — the render tick lives
//  on main, and a folder of two hundred shaders is not a one-frame job.
//
//  Names: the copy keeps its file name unless that name is taken, in which case it
//  becomes "Name 2", "Name 3"…. A name is taken if a file in the user folder has it,
//  or a built-in module does — built-ins win on name, so an import sharing one would
//  be hidden. A module in the shared folder is NOT a clash: the copy is meant to
//  outrank it, which is how "copy this shared module into Videoboy" works.
//

import Foundation

/// What happened to each file handed to the importer.
public struct ISFImportReport: Sendable {

    public enum Outcome: Equatable, Sendable {
        /// Copied into the library under `name`. `notes` lists companion files that
        /// could not come with it (e.g. a missing image); the module itself is in.
        case imported(name: String, notes: [String])
        /// An identical file is already in the library, under `name`.
        case alreadyImported(name: String)
        /// Not copied. `reason` says why, in words for the operator.
        case skipped(reason: String)
    }

    public struct Item: Sendable {
        public let source: URL
        public let outcome: Outcome
    }

    public internal(set) var items: [Item] = []

    public var importedNames: [String] {
        items.compactMap { if case .imported(let name, _) = $0.outcome { name } else { nil } }
    }

    /// One or two sentences for an alert or a status line.
    public var summary: String {
        let imported = importedNames.count
        let already = items.filter { if case .alreadyImported = $0.outcome { true } else { false } }.count
        let skipped = items.count - imported - already
        var parts: [String] = []
        parts.append(imported == 1 ? "Imported 1 module." : "Imported \(imported) modules.")
        if already > 0 { parts.append("\(already) already in the library.") }
        if skipped > 0 { parts.append("\(skipped) skipped.") }
        return parts.joined(separator: " ")
    }
}

/// Copies ISF files into, and removes them from, Videoboy's own ISF folder.
public enum ISFImporter {

    /// Imports every `.fs` file in `urls` (folders are walked) into `destination`.
    ///
    /// - Parameter reservedNames: lower-cased module names an import must not take.
    ///   Defaults to the built-in modules' names.
    public static func importFiles(
        _ urls: [URL],
        into destination: URL = ISFLibrary.userFolder,
        reservedNames: Set<String>? = nil
    ) -> ISFImportReport {
        var report = ISFImportReport()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Log.error(.isf, "could not create '\(destination.path)': \(error.localizedDescription)")
            for url in urls {
                report.items.append(.init(source: url, outcome: .skipped(
                    reason: "Videoboy's ISF folder could not be created: \(error.localizedDescription)")))
            }
            return report
        }

        let reserved = reservedNames ?? Set(
            ISFLibrary.fragmentFiles(in: ISFLibrary.builtinFolder)
                .map { $0.deletingPathExtension().lastPathComponent.lowercased() })

        for file in expand(urls) {
            let outcome = importOne(file, into: destination, reserved: reserved)
            report.items.append(.init(source: file, outcome: outcome))
        }
        Log.info(.isf, "import: \(report.summary)")
        return report
    }

    /// Moves an imported module (and its `.vs` partner) to the Trash.
    ///
    /// Only files inside `libraryFolder` can be removed: built-in modules ship with
    /// the app and the shared folder belongs to other applications.
    /// Imported images are left alone — several modules may share one.
    ///
    /// - Parameter trash: how a file is disposed of. The Trash, except in tests, which
    ///   must not fill the operator's real Trash on every run.
    public static func remove(
        _ url: URL, libraryFolder: URL = ISFLibrary.userFolder,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        guard isInside(url, folder: libraryFolder) else {
            throw ISFImportError.notInLibrary(url.path)
        }
        try trash(url)
        let vertex = url.deletingPathExtension().appendingPathExtension("vs")
        if FileManager.default.fileExists(atPath: vertex.path) {
            try trash(vertex)
        }
        Log.info(.isf, "moved '\(url.lastPathComponent)' to the Trash")
    }

    // MARK: - One file

    private static func importOne(_ source: URL, into destination: URL, reserved: Set<String>) -> ISFImportReport.Outcome {
        let fileManager = FileManager.default
        let data: Data
        let text: String
        do {
            data = try Data(contentsOf: source)
            guard let decoded = String(data: data, encoding: .utf8) else {
                return .skipped(reason: "\(source.lastPathComponent) is not a text file")
            }
            text = decoded
        } catch {
            return .skipped(reason: "\(source.lastPathComponent) could not be read: \(error.localizedDescription)")
        }

        let originalName = source.deletingPathExtension().lastPathComponent
        let document: ISFDocument
        do {
            document = try ISFDocument(source: text, name: originalName)
        } catch {
            return .skipped(reason: "\(source.lastPathComponent) is not an ISF file: \(error)")
        }

        // Already here: the very file, or a byte-identical copy of it.
        let existing = ISFLibrary.fragmentFiles(in: destination)
        if isInside(source, folder: destination) {
            return .alreadyImported(name: originalName)
        }
        for url in existing where (try? Data(contentsOf: url)) == data {
            return .alreadyImported(name: url.deletingPathExtension().lastPathComponent)
        }

        let taken = reserved.union(existing.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
        let name = availableName(originalName, taken: taken)
        let target = destination.appendingPathComponent(name).appendingPathExtension("fs")
        do {
            try data.write(to: target, options: .withoutOverwriting)
        } catch {
            return .skipped(reason: "\(source.lastPathComponent) could not be copied: \(error.localizedDescription)")
        }

        var notes: [String] = []
        let vertex = source.deletingPathExtension().appendingPathExtension("vs")
        if fileManager.fileExists(atPath: vertex.path) {
            let vertexTarget = target.deletingPathExtension().appendingPathExtension("vs")
            do {
                try fileManager.copyItem(at: vertex, to: vertexTarget)
            } catch {
                notes.append("its vertex shader could not be copied: \(error.localizedDescription)")
            }
        }

        // Images, at the same relative path so the header's PATH still resolves.
        let sourceFolder = source.deletingLastPathComponent()
        for (imageName, paths) in document.importedImageFiles {
            for path in paths {
                let byPath = sourceFolder.appendingPathComponent(path).standardizedFileURL
                // PATH, or a picture named after the import (isf.video editor exports),
                // copied under the name it was found by so the same lookup finds it again.
                let found = ISFProgram.importedImageURL(name: imageName, path: path, in: sourceFolder)?
                    .standardizedFileURL
                let from = found ?? byPath
                let copiedPath = (found == nil || found == byPath) ? path : from.lastPathComponent
                let to = destination.appendingPathComponent(copiedPath).standardizedFileURL
                guard isInside(to, folder: destination) else {
                    notes.append("image '\(path)' points outside the folder and was not copied")
                    continue
                }
                if fileManager.fileExists(atPath: to.path) { continue }
                guard fileManager.fileExists(atPath: from.path) else {
                    notes.append("image '\(path)' was not found beside the file")
                    continue
                }
                do {
                    try fileManager.createDirectory(
                        at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: from, to: to)
                } catch {
                    notes.append("image '\(path)' could not be copied: \(error.localizedDescription)")
                }
            }
        }
        for note in notes { Log.warn(.isf, "'\(name)': \(note)") }
        return .imported(name: name, notes: notes)
    }

    // MARK: - Helpers

    /// The `.fs` files named directly, plus every `.fs` inside the folders named.
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                files.append(url)   // reported as unreadable, not silently dropped
                continue
            }
            if isDirectory.boolValue {
                files.append(contentsOf: ISFLibrary.fragmentFiles(in: url))
            } else {
                files.append(url)
            }
        }
        return files
    }

    /// `name`, or `name 2`, `name 3`… — the first not in `taken` (compared lower-cased).
    static func availableName(_ name: String, taken: Set<String>) -> String {
        if !taken.contains(name.lowercased()) { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    /// True when `url` is below `folder`. Compared both as written and with symlinks
    /// resolved, because a path that does not exist yet (a copy's target) cannot be
    /// resolved, while its folder can (`/var` is `/private/var` on macOS).
    static func isInside(_ url: URL, folder: URL) -> Bool {
        func below(_ path: String, _ root: String) -> Bool {
            path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        let plain = below(url.standardizedFileURL.path, folder.standardizedFileURL.path)
        let resolved = below(url.standardizedFileURL.resolvingSymlinksInPath().path,
                             folder.standardizedFileURL.resolvingSymlinksInPath().path)
        return plain || resolved
    }
}

/// Why an import-library operation was refused.
public enum ISFImportError: Error, CustomStringConvertible {
    case notInLibrary(String)

    public var description: String {
        switch self {
        case .notInLibrary(let path):
            "only imported modules can be removed; '\(path)' is not in Videoboy's ISF folder"
        }
    }
}
