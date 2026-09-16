//
//  SelfQACheck.swift — where self-QA artifacts go, and what a check's verdict is.
//
//  Purpose : Every check writes the same three things in the same place: PNGs, an
//            optional metrics.json, and a result.txt saying pass/fail/blocked and
//            why. This file owns that convention so no check invents its own.
//  Inputs  : a check name and a list of `AssertionResult`s.
//  Outputs : selfqa/out/<check>/result.txt (+ whatever PNGs the check wrote there).
//  Connects: scripts/selfqa.sh runs a check by name; BUILD-PLAN acceptance items are
//            satisfied by the files this produces.
//  Extend  : add a new check by constructing a `SelfQACheck`, writing artifacts into
//            its `outputDirectory`, and calling `finish(with:)`.
//

import Foundation

/// The three verdicts a check can reach. `blocked` exists so missing hardware or a
/// missing permission never reads as a defect in the code.
public enum SelfQAVerdict: String {
    case pass
    case fail
    case blocked
}

/// Locates the repository on disk so checks can write next to the source.
public enum RepoPaths {
    /// Repository root: `$VIDEOBOY_REPO_ROOT` if set, otherwise the nearest ancestor
    /// of the current directory containing CLAUDE.md, otherwise the current directory.
    ///
    /// The environment variable is what scripts/ set, and is the reliable path. The
    /// walk-up is a convenience for running a test directly from an editor.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["VIDEOBOY_REPO_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("CLAUDE.md").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        Log.warn(.selfqa, "could not locate repo root; falling back to working directory")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// `selfqa/out/` — the root of all self-QA evidence.
    public static var selfQAOutput: URL { root.appendingPathComponent("selfqa/out", isDirectory: true) }

    /// `samples/` — test media provided by the human (plus generated fixtures).
    public static var samples: URL { root.appendingPathComponent("samples", isDirectory: true) }

    /// `config/` — machine-specific device identity.
    public static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
}

/// One self-QA check: a named output directory plus a verdict written at the end.
public final class SelfQACheck {
    public let name: String
    /// `selfqa/out/<name>/`. Created on init so a check can write into it immediately.
    public let outputDirectory: URL

    private var results: [AssertionResult] = []
    private var notes: [String] = []

    /// Creates (and empties) the check's output directory.
    ///
    /// Emptying matters: a stale PNG from a previous run is worse than no PNG,
    /// because it looks like fresh evidence.
    public init(name: String) {
        self.name = name
        self.outputDirectory = RepoPaths.selfQAOutput.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectory.path) {
            // Remove only the files this harness writes, so a hand-placed note survives.
            let artifacts = (try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
            for artifact in artifacts where ["png", "json", "txt"].contains(artifact.pathExtension) {
                try? fileManager.removeItem(at: artifact)
            }
        }
        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    /// Records one assertion and logs it immediately, so a crash mid-check still
    /// leaves a trail.
    public func record(_ result: AssertionResult) {
        results.append(result)
        if result.passed {
            Log.info(.selfqa, "\(name): \(result.line)")
        } else {
            Log.error(.selfqa, "\(name): \(result.line)")
        }
    }

    /// Records several assertions at once.
    public func record(_ batch: [AssertionResult]) { batch.forEach(record) }

    /// Adds a free-text line to result.txt — used for provenance (which sample file,
    /// which seed, which device) that is not itself a pass/fail.
    public func note(_ text: String) {
        notes.append(text)
        Log.info(.selfqa, "\(name): \(text)")
    }

    /// Full path for an artifact inside this check's directory.
    public func artifactURL(_ filename: String) -> URL {
        outputDirectory.appendingPathComponent(filename)
    }

    /// Convenience: write an image into this check's directory.
    @discardableResult
    public func writeImage(_ image: ImageBuffer, named filename: String) throws -> URL {
        let url = artifactURL(filename)
        try image.writePNG(to: url)
        return url
    }

    /// Writes result.txt and returns the verdict.
    ///
    /// - Parameter blockedReason: when non-nil the verdict is `blocked` regardless of
    ///   assertions — this is how absent hardware is reported without failing a phase.
    @discardableResult
    public func finish(blockedReason: String? = nil) -> SelfQAVerdict {
        let verdict: SelfQAVerdict
        if let blockedReason {
            verdict = .blocked
            notes.append("BLOCKED: \(blockedReason)")
        } else if results.isEmpty {
            verdict = .fail
            notes.append("no assertions were recorded — a check that asserts nothing proves nothing")
        } else {
            verdict = results.allSatisfy(\.passed) ? .pass : .fail
        }

        var lines: [String] = []
        lines.append("check:    \(name)")
        lines.append("verdict:  \(verdict.rawValue.uppercased())")
        lines.append("when:     \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("core:     \(Videoboy.version)")
        lines.append("")
        if !notes.isEmpty {
            lines.append("notes:")
            notes.forEach { lines.append("  \($0)") }
            lines.append("")
        }
        lines.append("assertions (\(results.filter(\.passed).count)/\(results.count) passed):")
        results.forEach { lines.append("  \($0.line)") }
        if verdict != .pass {
            lines.append("")
            lines.append("recent log:")
            Log.recent(30).forEach { lines.append("  \($0.formatted)") }
        }

        let text = lines.joined(separator: "\n") + "\n"
        let url = artifactURL("result.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Log.info(.selfqa, "\(name): \(verdict.rawValue.uppercased()) -> \(url.path)")
        } catch {
            Log.error(.selfqa, "could not write result.txt for \(name): \(error)")
        }
        return verdict
    }
}
