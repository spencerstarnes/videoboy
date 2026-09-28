//
//  BinPath.swift — bins inside bins, as paths.
//
//  Purpose : A library bin is identified by its PATH: "2019/Shoot A" is the bin
//            "Shoot A" inside the bin "2019". That is all nesting is — no bin table
//            with parent ids — so a clip's `bin` field, the catalog's `bin` column and
//            every bin menu keep working unchanged, and a library saved before bins
//            nested simply has every bin at the top level. These are the rules for
//            reading and changing such paths, kept here so they are unit-tested.
//  Inputs  : bin paths (String), file URLs.
//  Outputs : parents, leaves, children, renamed paths, display text.
//  Connects: ImportScan and FileTransfer (the folder tree a drop or import keeps),
//            the App's LibraryModel and library views (the tree the performer sees).
//  Extend  : the separator is "/" because a file-system folder name cannot contain
//            one; a name typed by hand has it replaced (`sanitisedLeaf`).
//

import Foundation

/// Rules for bin paths. A nil path is the library's top level.
public enum BinPath {

    public static let separator: Character = "/"

    /// What a path shows as in a menu: "2019 › Shoot A".
    public static func display(_ path: String) -> String {
        components(of: path).joined(separator: " › ")
    }

    /// The path's parts, outermost first.
    public static func components(of path: String) -> [String] {
        path.split(separator: separator, omittingEmptySubsequences: true).map(String.init)
    }

    /// The bin's own name: "Shoot A" for "2019/Shoot A".
    public static func leaf(of path: String) -> String {
        components(of: path).last ?? path
    }

    /// The bin holding this one, or nil at the top level.
    public static func parent(of path: String) -> String? {
        let parts = components(of: path)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: String(separator))
    }

    /// A child path: `name` inside `parent` (or at the top level when nil).
    public static func join(_ parent: String?, _ name: String) -> String {
        let clean = components(of: name).joined(separator: String(separator))
        guard let parent, !parent.isEmpty else { return clean }
        guard !clean.isEmpty else { return parent }
        return parent + String(separator) + clean
    }

    /// Every bin above this one, outermost first ("2019" for "2019/Shoot A").
    public static func ancestors(of path: String) -> [String] {
        let parts = components(of: path)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[0..<$0].joined(separator: String(separator)) }
    }

    /// Whether `path` is `ancestor` itself or somewhere inside it.
    public static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + String(separator))
    }

    /// `path` with its `oldPrefix` part replaced by `newPrefix` (nil = the top level),
    /// or nil when `path` is not within `oldPrefix`. How a rename or a delete carries
    /// the bins inside along with it.
    public static func replacingPrefix(of path: String, _ oldPrefix: String, with newPrefix: String?) -> String? {
        guard isWithin(path, oldPrefix) else { return nil }
        let rest = String(path.dropFirst(oldPrefix.count)).drop { $0 == separator }
        return rest.isEmpty ? newPrefix : join(newPrefix, String(rest))
    }

    /// A name typed by hand, made safe to be one level: a "/" would silently nest it.
    public static func sanitisedLeaf(_ name: String) -> String {
        name.replacingOccurrences(of: String(separator), with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The folders between `root` and a file inside it, as a bin path: "Sub/Deeper" for
    /// root/Sub/Deeper/clip.mov. Empty for a file directly in `root`; nil when the file
    /// is not inside `root` at all.
    public static func relativeFolder(of file: URL, below root: URL) -> String? {
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileParts.count > rootParts.count, Array(fileParts.prefix(rootParts.count)) == rootParts else {
            return nil
        }
        return fileParts[rootParts.count..<(fileParts.count - 1)].joined(separator: String(separator))
    }
}
