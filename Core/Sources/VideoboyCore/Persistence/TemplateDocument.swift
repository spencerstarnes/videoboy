//
//  TemplateDocument.swift — plain-text save and load (SPEC 16).
//
//  Purpose : The whole app state — graph shape, parameter values, mappings, layout,
//            clock settings — as human-readable JSON that survives being edited in a
//            text editor. Param codes (SPEC 13) are the mapping keys, so a template
//            keeps working when modules change.
//  Inputs  : a `TemplateDocument`, or a .vbt file on disk.
//  Outputs : the same, round-tripped exactly.
//  Connects: RenderGraph and ParamRegistry (what it describes), the File menu.
//  Extend  : add a field with a default value so older templates still load. Never
//            make a new field required, and never drop unknown keys — SPEC 16 says
//            unknown keys are preserved, not fatal.
//
//  Format choice: JSON rather than TOML. It is human-readable and hand-editable,
//  which is what SPEC 16 asks for, and Foundation encodes and decodes it without a
//  third-party dependency. Keys are sorted and output is pretty-printed so a saved
//  template diffs cleanly in git.
//

import Foundation

/// One node in a saved template.
public struct TemplateNode: Codable, Equatable {
    /// Matches `Node.identifier`, and doubles as the mapping slot name.
    public var identifier: String
    /// Which module implementation to instantiate.
    public var moduleType: String
    /// Parameter values by param code. Codes that no longer exist are kept on load
    /// and written back out, so downgrading an app version does not lose settings.
    public var parameters: [String: Double]
    /// For a source: the media file it plays, as a path relative to the repo.
    public var mediaPath: String?

    public init(
        identifier: String, moduleType: String,
        parameters: [String: Double] = [:], mediaPath: String? = nil
    ) {
        self.identifier = identifier
        self.moduleType = moduleType
        self.parameters = parameters
        self.mediaPath = mediaPath
    }
}

/// A saved mapping, addressed by param code.
public struct TemplateMapping: Codable, Equatable {
    public var source: ControlSource
    public var slot: String
    /// The raw param code string, not the enum, so an unrecognised code survives a
    /// round-trip instead of failing to decode.
    public var code: String

    public init(source: ControlSource, slot: String, code: String) {
        self.source = source
        self.slot = slot
        self.code = code
    }
}

/// Clock state worth restoring with a template.
public struct TemplateClock: Codable, Equatable {
    public var beatsPerMinute: Double
    public var beatsPerBar: Int
    public var subdivision: String

    public init(beatsPerMinute: Double = 120, beatsPerBar: Int = 4, subdivision: String = "1/4") {
        self.beatsPerMinute = beatsPerMinute
        self.beatsPerBar = beatsPerBar
        self.subdivision = subdivision
    }
}

/// Which panels are collapsed. Panels cannot move (SPEC 14.4), so this is the whole
/// of the layout state and stays trivial.
public struct TemplateLayout: Codable, Equatable {
    public var collapsedPanels: [String]

    public init(collapsedPanels: [String] = []) {
        self.collapsedPanels = collapsedPanels
    }
}

/// What one channel (A–D) held when the template was saved (version 3).
public struct TemplateChannel: Codable, Equatable {
    /// The clip file, by absolute path, when the channel played a file.
    public var mediaPath: String?
    /// In and out marks, 0...1 of the clip.
    public var inPoint: Double?
    public var outPoint: Double?
    public var isPlaying: Bool
    public var loopMode: LoopMode?
    /// A non-file source, as a library reference: `generator:<kind>`, `isf:<module>`,
    /// `source:<configured id>`. Nil for a file or an empty channel.
    public var reference: String?
    /// How the picture sits in the canvas (Fit / Fill / Stretch / Centre).
    public var framing: PreviewFill?

    public init(mediaPath: String? = nil, inPoint: Double? = nil, outPoint: Double? = nil,
                isPlaying: Bool = false, loopMode: LoopMode? = nil, reference: String? = nil,
                framing: PreviewFill? = nil) {
        self.mediaPath = mediaPath
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.isPlaying = isPlaying
        self.loopMode = loopMode
        self.reference = reference
        self.framing = framing
    }
}

/// A complete saved setup.
public struct TemplateDocument: Codable, Equatable {

    /// Bumped when the format changes. Loading tolerates older values.
    ///
    /// 2 (2026-09-23): the effect chains (`chains`), now that a chain is data rather
    /// than hard-wired. A version-1 template has none and loads with the standard
    /// chain, its values applied by slot and code as before (`chains(orStandard:)`).
    ///
    /// 3 (2026-09-27): what each channel holds (`channels`) — clip, marks, playing,
    /// loop mode, or a generator / configured-source reference — so opening a template
    /// brings the show back, not only its settings.
    public static let currentVersion = 3

    public var version: Int
    /// Free-text name shown in the window subtitle.
    public var name: String
    public var nodes: [TemplateNode]
    public var edges: [GraphEdge]
    public var mappings: [TemplateMapping]
    public var clock: TemplateClock
    public var layout: TemplateLayout
    /// Each sub-mix's effect chain, by bus (`one`, `two`). Nil in a template saved
    /// before chains were data.
    public var chains: [String: EffectChain]?
    /// Each channel's contents, by letter. Nil before version 3.
    public var channels: [String: TemplateChannel]?

    public init(
        version: Int = TemplateDocument.currentVersion,
        name: String = "untitled",
        nodes: [TemplateNode] = [],
        edges: [GraphEdge] = [],
        mappings: [TemplateMapping] = [],
        clock: TemplateClock = TemplateClock(),
        layout: TemplateLayout = TemplateLayout(),
        chains: [String: EffectChain]? = nil,
        channels: [String: TemplateChannel]? = nil
    ) {
        self.version = version
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.mappings = mappings
        self.clock = clock
        self.layout = layout
        self.chains = chains
        self.channels = channels
    }

    /// The chain a bus should run: the saved one, or the standard chain for a
    /// template from before chains were saved (its values still apply by slot, since
    /// the standard chain uses the slots the hard-wired one did).
    public func chain(for bus: ChainBus) -> EffectChain {
        chains?[bus.rawValue] ?? .standard
    }

    // Every field has a default, so a hand-edited template missing a section still
    // loads. This is the mechanism behind SPEC 16's "unknown keys are non-fatal".
    private enum CodingKeys: String, CodingKey {
        case version, name, nodes, edges, mappings, clock, layout, chains, channels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? TemplateDocument.currentVersion
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "untitled"
        nodes = try container.decodeIfPresent([TemplateNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([GraphEdge].self, forKey: .edges) ?? []
        mappings = try container.decodeIfPresent([TemplateMapping].self, forKey: .mappings) ?? []
        clock = try container.decodeIfPresent(TemplateClock.self, forKey: .clock) ?? TemplateClock()
        layout = try container.decodeIfPresent(TemplateLayout.self, forKey: .layout) ?? TemplateLayout()
        chains = try container.decodeIfPresent([String: EffectChain].self, forKey: .chains)
        channels = try container.decodeIfPresent([String: TemplateChannel].self, forKey: .channels)

        if version > TemplateDocument.currentVersion {
            Log.warn(.template, "template is version \(version) but this build understands \(TemplateDocument.currentVersion); loading anyway")
        }
    }

    // MARK: - File I/O

    /// Errors reading or writing a template.
    public enum TemplateError: Error, CustomStringConvertible {
        case cannotRead(URL, Error)
        case cannotParse(URL, Error)
        case cannotWrite(URL, Error)

        public var description: String {
            switch self {
            case .cannotRead(let url, let error): "cannot read \(url.lastPathComponent): \(error)"
            case .cannotParse(let url, let error): "\(url.lastPathComponent) is not a valid template: \(error)"
            case .cannotWrite(let url, let error): "cannot write \(url.lastPathComponent): \(error)"
            }
        }
    }

    /// Writes the template as pretty-printed, key-sorted JSON.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        // Sorted and pretty so a template is readable and diffable by hand, which is
        // the whole point of a plain-text format.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url)
            Log.info(.template, "saved template '\(name)' -> \(url.path)")
        } catch {
            throw TemplateError.cannotWrite(url, error)
        }
    }

    /// Reads a template from disk.
    public static func read(from url: URL) throws -> TemplateDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TemplateError.cannotRead(url, error)
        }
        do {
            let document = try JSONDecoder().decode(TemplateDocument.self, from: data)
            Log.info(.template, "loaded template '\(document.name)' (\(document.nodes.count) nodes, \(document.mappings.count) mappings)")
            return document
        } catch {
            throw TemplateError.cannotParse(url, error)
        }
    }

    // MARK: - Bridging to the live objects

    /// Builds a template from the current graph and registry.
    public static func capture(
        name: String, graph: RenderGraph, registry: ParamRegistry, clock: TemplateClock,
        chains: [ChainBus: EffectChain]? = nil,
        channels: [String: TemplateChannel]? = nil
    ) -> TemplateDocument {
        let nodes = graph.nodes.values.map { node -> TemplateNode in
            var values: [String: Double] = [:]
            for parameter in node.parameters {
                if let value = registry.value(slot: node.identifier, code: parameter.code) {
                    values[parameter.code.rawValue] = value
                }
            }
            return TemplateNode(
                identifier: node.identifier,
                moduleType: String(describing: type(of: node)),
                parameters: values
            )
        }
        // Sorted so two captures of the same state produce byte-identical files.
        .sorted { $0.identifier < $1.identifier }

        let mappings = registry.bindings.map {
            TemplateMapping(source: $0.source, slot: $0.slot, code: $0.code.rawValue)
        }

        return TemplateDocument(
            name: name,
            nodes: nodes,
            edges: graph.edges.sorted { ($0.to, $0.inputIndex) < ($1.to, $1.inputIndex) },
            mappings: mappings,
            clock: clock,
            chains: chains.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) },
            channels: channels
        )
    }

    /// Applies this template's parameter values and mappings to a live registry.
    ///
    /// - Returns: the number of mappings that could not be understood by this build.
    ///   They are reported, and remain in the document, but are not bound.
    @discardableResult
    public func apply(to registry: ParamRegistry) -> Int {
        for node in nodes {
            for (rawCode, value) in node.parameters {
                guard let code = ParamCode(rawValue: rawCode) else {
                    Log.warn(.template, "template holds unknown param code '\(rawCode)' on '\(node.identifier)'; keeping it but not applying")
                    continue
                }
                registry.setValue(value, slot: node.identifier, code: code)
            }
        }

        var unknown = 0
        for mapping in mappings {
            guard let code = ParamCode(rawValue: mapping.code) else {
                Log.warn(.template, "template maps \(mapping.source.description) to unknown code '\(mapping.code)'; preserved but inactive")
                unknown += 1
                continue
            }
            registry.bind(ControlBinding(source: mapping.source, slot: mapping.slot, code: code))
        }
        return unknown
    }
}
