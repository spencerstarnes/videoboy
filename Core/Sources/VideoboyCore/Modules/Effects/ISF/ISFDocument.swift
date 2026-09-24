//
//  ISFDocument.swift — one ISF file, parsed (SPEC 8).
//
//  Purpose : Reads an Interactive Shader Format file: a JSON header in a leading
//            `/*{ … }*/` comment, followed by a GLSL fragment shader. This type holds
//            what the header declares (inputs, passes, categories) and the GLSL body,
//            and classifies the file as an effect, generator or transition.
//  Inputs  : the text of a `.fs` file and a display name (usually the file name).
//  Outputs : an `ISFDocument`, or an `ISFParseError` saying what is wrong and where.
//  Connects: ISFMetalGenerator (turns the body into Metal), ISFNode (reads the inputs
//            and passes), ISFLibrary (parses every file it finds).
//  Extend  : a new header key is a field here plus a line in `init(source:name:)`.
//            Unknown keys are ignored, as every ISF host does, so a file written for
//            VDMX still loads.
//
//  Pure Swift and pure data: no Metal, no files. That is what lets every rule here be
//  unit-tested on strings.
//
//  VIDEOBOY EXTENSIONS (ignored by other ISF hosts, so files stay portable):
//    - per input:  "VIDEOBOY_CODE": "51A"   — the stable param code (SPEC 13)
//    - top level:  "VIDEOBOY": { "IDENTITY_AT_DEFAULTS": true }
//                  — with every input at its DEFAULT the shader returns its input
//                  unchanged, so the host may skip the pass entirely.
//

import Foundation

/// What an ISF file is for, decided by which image inputs it declares (ISF spec).
public enum ISFKind: String, Codable, Sendable {
    /// Has an `inputImage`: transforms one picture. Lives in the FX layer chain.
    case effect
    /// No image input: makes a picture from nothing. Lives with the generators.
    case generator
    /// `startImage` + `endImage` + `progress`: a crossfade shape.
    case transition
}

/// The ISF input types. Raw values are the spellings used in the JSON header.
public enum ISFInputType: String, Codable, Sendable {
    case float
    case bool
    case long
    case event
    case color
    case point2D
    case image
    case audio
    case audioFFT
    case cube
}

/// One declared input — a control the operator sees, or an image the host supplies.
public struct ISFInput: Equatable, Sendable {
    /// The uniform name used in the GLSL body. Also the stable key for this input.
    public let name: String
    public let type: ISFInputType
    /// Human label; falls back to `name`.
    public let label: String
    /// Components: 1 for scalars, 2 for `point2D`, 4 for `color`. Empty for images.
    public let defaultValue: [Double]
    public let minimum: [Double]?
    public let maximum: [Double]?
    /// For `long`: the values the popup offers, and their labels.
    public let values: [Int]
    public let labels: [String]
    /// The Videoboy param code declared in the file, if any (SPEC 13).
    public let videoboyCode: String?

    /// Number of float components this input occupies, 0 for images and audio.
    public var componentCount: Int {
        switch type {
        case .float, .bool, .long, .event: 1
        case .point2D: 2
        case .color: 4
        case .image, .audio, .audioFFT, .cube: 0
        }
    }

    /// Whether this input is a picture rather than a value.
    public var isImage: Bool { type == .image || type == .audio || type == .audioFFT || type == .cube }

    /// A `point2D` with no MIN or MAX: a position in the frame, which VDMX hands the
    /// shader in PIXELS while the file's DEFAULT is written 0…1. Vidvox's own Vertex
    /// Manipulator divides such points by RENDERSIZE and defaults them to the frame's
    /// corners; every point that declares a range is used as given.
    public var isFramePosition: Bool { type == .point2D && minimum == nil && maximum == nil }
}

/// One render pass. A file with no `PASSES` has exactly one, rendering to output.
public struct ISFPass: Equatable, Sendable {
    /// Name of the buffer this pass writes, readable by later passes as an image.
    public let target: String?
    /// Keep the buffer between frames (trails, feedback).
    public let persistent: Bool
    /// Store at 16-bit float rather than 8-bit, for accumulation without banding.
    public let float: Bool
    /// Size expressions such as `"$WIDTH/2"`. Nil means the render size.
    public let widthExpression: String?
    public let heightExpression: String?
}

/// Why a file could not be read. Each case says what to fix.
public enum ISFParseError: Error, Equatable, CustomStringConvertible {
    case missingHeader
    case unterminatedHeader
    case invalidJSON(String)
    case invalidInput(name: String, reason: String)
    case invalidPass(index: Int, reason: String)

    public var description: String {
        switch self {
        case .missingHeader:
            "no ISF header: the file must start with a /*{ … }*/ JSON comment"
        case .unterminatedHeader:
            "the ISF header comment is never closed with */"
        case .invalidJSON(let detail):
            "the ISF header is not valid JSON: \(detail)"
        case .invalidInput(let name, let reason):
            "input '\(name)': \(reason)"
        case .invalidPass(let index, let reason):
            "pass \(index): \(reason)"
        }
    }
}

/// A parsed ISF file.
public struct ISFDocument: Equatable, Sendable {
    /// Display name, usually the file name without extension.
    public let name: String
    public let summary: String
    public let credit: String
    public let categories: [String]
    public let inputs: [ISFInput]
    public let passes: [ISFPass]
    /// Names of images the file imports from disk. Parsed so a file that uses them is
    /// reported honestly; loading them is not built yet.
    public let importedImages: [String]
    /// The files those images come from (each `PATH`, relative to the `.fs` file), so
    /// importing the shader can copy its pictures with it. Cube maps list six paths.
    public let importedImagePaths: [String]
    /// Each imported image's file(s), by its name: one path, or six for a cube map.
    public let importedImageFiles: [String: [String]]
    /// The imports that are cube maps: `"TYPE": "cube"`, or six PATHs.
    public let importedCubeMaps: [String]
    /// `VIDEOBOY.IDENTITY_AT_DEFAULTS` — see the file header.
    public let identityAtDefaults: Bool
    /// The GLSL after the header.
    public let fragmentSource: String
    /// 1-based line in the original file where `fragmentSource` starts, so a compiler
    /// error can be reported against the line the author sees.
    public let fragmentStartLine: Int
    /// The GLSL of the `.vs` beside the file, when it does more than the ISF default
    /// (`ISFLibrary.isPassThroughVertexShader`). Nil means the default vertex stage.
    public let vertexSource: String?

    /// Effect, generator or transition, by the ISF rules.
    public var kind: ISFKind {
        let imageNames = Set(inputs.filter { $0.type == .image }.map(\.name))
        if imageNames.contains("inputImage") { return .effect }
        let hasProgress = inputs.contains { $0.name == "progress" && $0.type == .float }
        if imageNames.contains("startImage"), imageNames.contains("endImage"), hasProgress {
            return .transition
        }
        return .generator
    }

    /// Inputs that carry values (everything except images and audio), in file order.
    public var valueInputs: [ISFInput] { inputs.filter { !$0.isImage } }

    /// Image inputs, in file order. `inputImage` is the effect's own picture.
    public var imageInputs: [ISFInput] { inputs.filter { $0.type == .image } }

    /// `audio` and `audioFFT` inputs, in file order: images the host fills with sound.
    public var audioInputs: [ISFInput] { inputs.filter { $0.type == .audio || $0.type == .audioFFT } }

    /// Parses the text of a `.fs` file.
    ///
    /// - Throws: `ISFParseError` naming what is wrong. Never crashes on bad input — a
    ///   broken file must show up greyed with a reason, not take the app down.
    public init(source rawSource: String, name: String, vertexSource: String? = nil) throws {
        self.name = name
        self.vertexSource = vertexSource.map(ISFDocument.normalisingLineEndings)
        // One line-ending convention from here on. Files from Windows-era VDMX packs
        // use CRLF, and some old Mac ones bare CR; Metal counts any of them as a line
        // break, so everything downstream must agree on what a line is or error lines
        // stop mapping back to the file. The author's editor numbers lines the same way.
        let source = ISFDocument.normalisingLineEndings(rawSource)

        // The header is the FIRST block comment and must open with `{`. Leading
        // whitespace and line comments are tolerated; anything else before it is not ISF.
        guard let open = source.range(of: "/*") else { throw ISFParseError.missingHeader }
        let beforeHeader = source[source.startIndex..<open.lowerBound]
        guard ISFDocument.isValidPreamble(beforeHeader) else { throw ISFParseError.missingHeader }
        guard let close = source.range(of: "*/", range: open.upperBound..<source.endIndex) else {
            throw ISFParseError.unterminatedHeader
        }
        let jsonText = String(source[open.upperBound..<close.lowerBound])
        guard jsonText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw ISFParseError.missingHeader
        }

        let root: [String: Any]
        do {
            let object = try JSONSerialization.jsonObject(
                with: Data(jsonText.utf8), options: [.fragmentsAllowed])
            guard let dictionary = object as? [String: Any] else {
                throw ISFParseError.invalidJSON("the header is not a JSON object")
            }
            root = dictionary
        } catch let error as ISFParseError {
            throw error
        } catch {
            throw ISFParseError.invalidJSON(error.localizedDescription)
        }

        let headerText = source[source.startIndex..<close.upperBound]
        fragmentStartLine = GLSLTokenizer.lineBreakCount(headerText) + 1
        fragmentSource = String(source[close.upperBound...])

        summary = root["DESCRIPTION"] as? String ?? ""
        credit = root["CREDIT"] as? String ?? ""
        categories = root["CATEGORIES"] as? [String] ?? []

        var parsedInputs: [ISFInput] = []
        for raw in root["INPUTS"] as? [[String: Any]] ?? [] {
            parsedInputs.append(try ISFDocument.parseInput(raw))
        }
        inputs = parsedInputs

        // ISF v1 listed persistent buffers separately; v2 marks the pass instead.
        // Accept both, so older files keep their trails.
        var persistentNames = Set<String>()
        if let list = root["PERSISTENT_BUFFERS"] as? [String] {
            persistentNames.formUnion(list)
        } else if let table = root["PERSISTENT_BUFFERS"] as? [String: Any] {
            persistentNames.formUnion(table.keys)
        }

        var parsedPasses: [ISFPass] = []
        for (index, raw) in (root["PASSES"] as? [[String: Any]] ?? []).enumerated() {
            let target = raw["TARGET"] as? String
            if let target, target.isEmpty {
                throw ISFParseError.invalidPass(index: index, reason: "TARGET is empty")
            }
            parsedPasses.append(ISFPass(
                target: target,
                persistent: ISFDocument.truthy(raw["PERSISTENT"])
                    || (target.map { persistentNames.contains($0) } ?? false),
                float: ISFDocument.truthy(raw["FLOAT"]),
                widthExpression: ISFDocument.expression(raw["WIDTH"]),
                heightExpression: ISFDocument.expression(raw["HEIGHT"])
            ))
        }
        if parsedPasses.isEmpty {
            parsedPasses = [ISFPass(
                target: nil, persistent: false, float: false,
                widthExpression: nil, heightExpression: nil)]
        }
        passes = parsedPasses

        // Two shapes: ISF 2 keys the images by name, ISF 1 lists them with a NAME.
        let importedEntries: [(name: String, entry: [String: Any])]
        if let imported = root["IMPORTED"] as? [String: Any] {
            importedEntries = imported.keys.sorted().map { ($0, imported[$0] as? [String: Any] ?? [:]) }
        } else if let imported = root["IMPORTED"] as? [[String: Any]] {
            importedEntries = imported.compactMap { entry in
                (entry["NAME"] as? String).map { ($0, entry) }
            }
        } else {
            importedEntries = []
        }
        importedImages = importedEntries.map(\.name)
        importedCubeMaps = importedEntries.filter { item in
            (item.entry["TYPE"] as? String) == "cube" || (item.entry["PATH"] as? [String])?.count == 6
        }.map(\.name)
        importedImageFiles = Dictionary(importedEntries.map { item -> (String, [String]) in
            if let path = item.entry["PATH"] as? String { return (item.name, [path]) }
            return (item.name, item.entry["PATH"] as? [String] ?? [])
        }, uniquingKeysWith: { first, _ in first })
        importedImagePaths = importedEntries.flatMap { item -> [String] in
            if let path = item.entry["PATH"] as? String { return [path] }
            return item.entry["PATH"] as? [String] ?? []
        }

        let videoboy = root["VIDEOBOY"] as? [String: Any] ?? [:]
        identityAtDefaults = ISFDocument.truthy(videoboy["IDENTITY_AT_DEFAULTS"])
    }

    // MARK: - Header helpers

    /// CRLF and bare CR become LF.
    static func normalisingLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Check if the preamble before the ISF header contains only whitespace and line comments.
    /// Many ISF files in the wild have metadata comments (like `//#SaturdayShader`) before the header.
    private static func isValidPreamble(_ text: Substring) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace {
                index = text.index(after: index)
                continue
            }
            // Check for line comment
            if index < text.index(text.endIndex, offsetBy: -1) {
                let next = text.index(after: index)
                if text[index] == "/" && text[next] == "/" {
                    // Skip to end of line
                    while index < text.endIndex && text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    if index < text.endIndex { index = text.index(after: index) } // skip the newline
                    continue
                }
            }
            // Found something that's not whitespace or line comment
            return false
        }
        return true
    }

    private static func parseInput(_ raw: [String: Any]) throws -> ISFInput {
        guard let name = raw["NAME"] as? String, !name.isEmpty else {
            throw ISFParseError.invalidInput(name: "?", reason: "missing NAME")
        }
        guard let typeName = raw["TYPE"] as? String else {
            throw ISFParseError.invalidInput(name: name, reason: "missing TYPE")
        }
        guard let type = ISFInputType(rawValue: typeName) else {
            throw ISFParseError.invalidInput(name: name, reason: "unknown TYPE '\(typeName)'")
        }
        guard name.first.map({ $0.isLetter || $0 == "_" }) == true,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw ISFParseError.invalidInput(name: name, reason: "NAME is not a valid identifier")
        }

        let components: Int
        switch type {
        case .float, .bool, .long, .event: components = 1
        case .point2D: components = 2
        case .color: components = 4
        case .image, .audio, .audioFFT, .cube: components = 0
        }

        let values = (raw["VALUES"] as? [Any] ?? []).compactMap { number($0).map { Int($0) } }
        let labels = raw["LABELS"] as? [String] ?? []

        // A missing DEFAULT is legal; the ISF convention is zero (or the first
        // VALUES entry for a popup, so the control opens on something it offers).
        var fallback = Array(repeating: 0.0, count: components)
        if type == .long, let first = values.first { fallback = [Double(first)] }
        if type == .color { fallback = [0, 0, 0, 1] }
        let defaultValue = vector(raw["DEFAULT"], count: components) ?? fallback

        return ISFInput(
            name: name,
            type: type,
            label: raw["LABEL"] as? String ?? name,
            defaultValue: defaultValue,
            minimum: vector(raw["MIN"], count: components),
            // For audio, MAX is the number of samples or bins the shader wants.
            maximum: (type == .audio || type == .audioFFT)
                ? number(raw["MAX"]).map { [$0] }
                : vector(raw["MAX"], count: components),
            values: values,
            labels: labels,
            videoboyCode: raw["VIDEOBOY_CODE"] as? String
        )
    }

    /// A JSON number, or a bool read as 0/1.
    private static func number(_ value: Any?) -> Double? {
        if let bool = value as? Bool { return bool ? 1 : 0 }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    /// A scalar or an array of numbers, as exactly `count` components.
    private static func vector(_ value: Any?, count: Int) -> [Double]? {
        guard count > 0, let value else { return nil }
        if let array = value as? [Any] {
            let numbers = array.compactMap { number($0) }
            guard numbers.count >= count else { return nil }
            return Array(numbers.prefix(count))
        }
        if let scalar = number(value) { return Array(repeating: scalar, count: count) }
        return nil
    }

    /// ISF writes flags as true/false, 1/0, or occasionally as strings.
    private static func truthy(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let string = value as? String { return string == "true" || string == "1" }
        return false
    }

    /// A pass size: an expression string, or a bare number written as one.
    private static func expression(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
