//
//  ISFLibrary.swift — finding ISF files on disk (SPEC 8).
//
//  Purpose : Lists every `.fs` file in the places ISF modules live and parses each
//            one, keeping the failures WITH their reasons. A broken file must show up
//            greyed with an explanation, never vanish and never crash (SPEC 1.5).
//  Inputs  : folder URLs; by default the three standard ones below.
//  Outputs : `[ISFLibraryEntry]`, sorted by name, each a parsed document or an error.
//  Connects: ISFDocument (parsing), the FX panel's Add menu and the Asset Browser
//            (consumers, once wired — see docs/ISF-SYSTEM.md), ISFNode (loads the
//            source of an entry the operator picks).
//  Extend  : a new location is one more `Folder` case and a line in `standardFolders`.
//            Hot reload (FSEvents) is planned (ISF-PLAN M6) and will call `scan` again.
//
//  Parsing only. Converting and compiling happen later, off the render path, when a
//  module is actually used (ISFCompiler) — scanning 200 files must not compile 200.
//

import Foundation

/// One `.fs` file and what became of it.
public struct ISFLibraryEntry: Sendable {
    /// Where modules can come from, in precedence order.
    public enum Folder: String, Sendable {
        /// Shipped inside Videoboy.app; the default modules. Read-only.
        case builtin
        /// `~/Library/Application Support/Videoboy/ISF` — the browser's Import target.
        case user
        /// `~/Library/Graphics/ISF` — the cross-application standard folder.
        case shared
    }

    public let url: URL
    public let folder: Folder
    /// The file name without extension; what the card and the Add menu show.
    public let name: String
    /// The file's text, kept so the node can compile it without a second read.
    public let source: String?
    /// The `.vs` partner's text, when it is more than the ISF default.
    public var vertexSource: String? = nil
    public let result: Result<ISFDocument, ISFLibraryError>

    public var document: ISFDocument? { try? result.get() }
}

/// Why a library entry is not usable.
public enum ISFLibraryError: Error, Equatable, CustomStringConvertible, Sendable {
    case unreadable(String)
    case parse(ISFParseError)
    /// A same-named file earlier in the precedence order wins.
    case shadowed(by: String)

    public var description: String {
        switch self {
        case .unreadable(let detail): "could not read the file: \(detail)"
        case .parse(let error): error.description
        case .shadowed(let path): "hidden by a file of the same name at \(path)"
        }
    }
}

/// Scans for ISF files.
public enum ISFLibrary {

    /// The built-in modules: inside the app bundle when running as the app, or the
    /// repository copy when running tests and self-QA from a checkout.
    public static var builtinFolder: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("ISF/Builtin", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return RepoPaths.root.appendingPathComponent("App/Resources/ISF/Builtin", isDirectory: true)
    }

    /// Videoboy's own copy of every imported module. Importing COPIES files here
    /// (ISFImporter), so a module keeps working after the original is moved or deleted.
    public static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Videoboy/ISF", isDirectory: true)
    }

    /// The cross-application folder VDMX and the ISF Editor install into. Read, never written.
    public static var sharedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Graphics/ISF", isDirectory: true)
    }

    /// The three standard locations, in precedence order.
    public static var standardFolders: [(URL, ISFLibraryEntry.Folder)] {
        [(builtinFolder, .builtin), (userFolder, .user), (sharedFolder, .shared)]
    }

    /// Lists and parses every `.fs` file under the given folders (recursively).
    ///
    /// A missing folder is normal (most machines have no shared ISF folder) and is
    /// skipped quietly. Duplicate names resolve to the earliest folder; the later ones
    /// stay in the list marked `.shadowed` so the operator can see why.
    public static func scan(_ folders: [(URL, ISFLibraryEntry.Folder)] = standardFolders) -> [ISFLibraryEntry] {
        var entries: [ISFLibraryEntry] = []
        var winners: [String: URL] = [:]

        for (folder, kind) in folders {
            for url in fragmentFiles(in: folder) {
                let name = url.deletingPathExtension().lastPathComponent
                let key = name.lowercased()
                if let winner = winners[key] {
                    Log.warn(.isf, "'\(url.path)' is hidden by '\(winner.path)'")
                    entries.append(ISFLibraryEntry(
                        url: url, folder: kind, name: name, source: nil,
                        result: .failure(.shadowed(by: winner.path))))
                    continue
                }
                winners[key] = url
                entries.append(load(url, folder: kind, name: name))
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads and parses one file.
    static func load(_ url: URL, folder: ISFLibraryEntry.Folder, name: String) -> ISFLibraryEntry {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.error(.isf, "could not read '\(url.path)': \(error.localizedDescription)")
            return ISFLibraryEntry(url: url, folder: folder, name: name, source: nil,
                                   result: .failure(.unreadable(error.localizedDescription)))
        }
        // The `.vs` partner, kept only when it does more than the default — a default
        // one changes nothing, and dropping it keeps such files on the faster path.
        var vertexSource: String?
        let vertexShader = url.deletingPathExtension().appendingPathExtension("vs")
        if FileManager.default.fileExists(atPath: vertexShader.path) {
            do {
                let text = try String(contentsOf: vertexShader, encoding: .utf8)
                if !isPassThroughVertexShader(text) { vertexSource = text }
            } catch {
                return ISFLibraryEntry(url: url, folder: folder, name: name, source: source,
                                       result: .failure(.unreadable("its vertex shader: \(error.localizedDescription)")))
            }
        }
        do {
            let document = try ISFDocument(source: source, name: name, vertexSource: vertexSource)
            var entry = ISFLibraryEntry(url: url, folder: folder, name: name, source: source, result: .success(document))
            entry.vertexSource = vertexSource
            return entry
        } catch let error as ISFParseError {
            Log.warn(.isf, "'\(name)': \(error.description)")
            return ISFLibraryEntry(url: url, folder: folder, name: name, source: source, result: .failure(.parse(error)))
        } catch {
            return ISFLibraryEntry(url: url, folder: folder, name: name, source: source,
                                   result: .failure(.unreadable(error.localizedDescription)))
        }
    }

    /// Whether a `.vs` file only does what the default vertex stage already does.
    ///
    /// Many packs ship every shader with a `.vs` whose whole body is
    /// `isf_vertShaderInit();` — the ISF default, which Videoboy's full-screen triangle
    /// already is. Rejecting those as "custom vertex shader" turned whole packs into
    /// "failed to load" for nothing. Comments and whitespace are ignored; anything
    /// else in the body is a real vertex shader and still unsupported.
    public static func isPassThroughVertexShader(_ source: String) -> Bool {
        var text = source
        // Block comments, then line comments.
        while let open = text.range(of: "/*") {
            guard let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined()
        let compact = text.filter { !$0.isWhitespace }
        return compact == "voidmain(){isf_vertShaderInit();}"
            || compact == "voidmain(void){isf_vertShaderInit();}"
    }

    /// Every `.fs` file below `folder`, in a stable order.
    public static func fragmentFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "fs" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}

public extension ISFNode {

    /// A node running one of the built-in modules (`Colour`, `Transform`, `Echo`),
    /// compiling in the background. This is the one call the engine needs to swap a
    /// native effect for its ISF port: same identifier, same param codes, so every
    /// fader, mapping and saved template reaches it unchanged.
    ///
    /// Until the program arrives the node passes its input through — which is also
    /// what every built-in does at its boot defaults, so nothing visible happens.
    /// A missing file fails the node visibly (`state == .failed`) rather than crashing.
    static func builtin(
        _ name: String, identifier: String,
        context: MetalContext? = MetalContext.shared, compiler: ISFCompiler = .shared
    ) -> ISFNode {
        let node = ISFNode(identifier: identifier, context: context)
        let url = ISFLibrary.builtinFolder.appendingPathComponent("\(name).fs")
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            node.load(source: source, name: name, resourceDirectory: ISFLibrary.builtinFolder, compiler: compiler)
        } catch {
            Log.error(.isf, "built-in module '\(name)' is missing from \(url.path)")
            node.markFailed("built-in module '\(name)' is missing")
        }
        return node
    }
}
