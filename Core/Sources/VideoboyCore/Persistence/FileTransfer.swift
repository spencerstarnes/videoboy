//
//  FileTransfer.swift — Add, Move or Copy files into the library (proposal §5).
//
//  Purpose : Lightroom's three import methods. Add catalogs files where they are;
//            Move moves them to a destination; Copy copies them and leaves the
//            originals. Copies are written SAFELY: into `<destination>/.videoboy-partial/`
//            and renamed into place only when complete, so a cancelled or failed copy
//            never leaves half a clip that looks whole.
//  Inputs  : file URLs, a method, a destination folder.
//  Outputs : the URLs to catalog (the originals for Add, the new files otherwise) and
//            the failures, by file name.
//  Connects: the App's ImportJob, which runs this on its background queue first.
//  Extend  : Copy + Optimize (0.4.10) adds a method that writes the optimized file
//            beside the copy through the same partial-then-rename rule.
//
//  THREADING: blocking file I/O. Call it off the main thread, never on the tick.
//

import Foundation

/// How files enter the library.
public enum ImportMethod: String, CaseIterable, Sendable {
    case add, move, copy

    /// Whether the method writes files to a destination.
    public var usesDestination: Bool { self != .add }
}

/// Moves and copies files for an import.
public enum FileTransfer {

    /// The folder copies are written into before they are complete.
    public static let partialFolderName = ".videoboy-partial"

    public struct Result: Sendable {
        /// What to catalog, in the order given.
        public var urls: [URL] = []
        /// "name — reason" for each file that could not be transferred.
        public var failures: [String] = []
    }

    /// Transfers files by `method` into `destination` (ignored for Add).
    ///
    /// - Parameters:
    ///   - progress: called before each file with its name.
    ///   - isCancelled: polled between files; what is done stays done.
    public static func transfer(
        _ urls: [URL], method: ImportMethod, to destination: URL?,
        isCancelled: () -> Bool = { false },
        progress: (String) -> Void = { _ in }
    ) -> Result {
        var result = Result()
        guard method.usesDestination else {
            result.urls = urls
            return result
        }
        guard let destination else {
            result.failures = urls.map { "\($0.lastPathComponent) — no destination chosen" }
            return result
        }
        let files = FileManager.default
        let partial = destination.appendingPathComponent(partialFolderName, isDirectory: true)
        do {
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            if method == .copy { try files.createDirectory(at: partial, withIntermediateDirectories: true) }
        } catch {
            result.failures = urls.map { "\($0.lastPathComponent) — \(error.localizedDescription)" }
            return result
        }
        defer {
            // Only ever removed when empty: a leftover means something to report, not delete.
            if method == .copy, (try? files.contentsOfDirectory(atPath: partial.path))?.isEmpty == true {
                try? files.removeItem(at: partial)
            }
        }
        for url in urls {
            if isCancelled() { break }
            progress(url.lastPathComponent)
            let target = freeName(for: url.lastPathComponent, in: destination)
            do {
                switch method {
                case .add:
                    break
                case .move:
                    try files.moveItem(at: url, to: target)
                case .copy:
                    let working = partial.appendingPathComponent(target.lastPathComponent)
                    try? files.removeItem(at: working)
                    // Resolve links: copying a symlink would copy a pointer, not the clip.
                    do {
                        try files.copyItem(at: url.resolvingSymlinksInPath(), to: working)
                        try files.moveItem(at: working, to: target)
                    } catch {
                        try? files.removeItem(at: working)
                        throw error
                    }
                }
                result.urls.append(target)
            } catch {
                result.failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return result
    }

    /// `name` in `folder`, or "name 2", "name 3"… when taken. Never overwrites.
    public static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }
}
