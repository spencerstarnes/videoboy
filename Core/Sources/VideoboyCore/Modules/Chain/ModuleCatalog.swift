//
//  ModuleCatalog.swift — every effect a chain can hold, and how to make one.
//
//  Purpose : One list of modules, whatever they are made of. A native node (the
//            datamosh, the composite codec, feedback, freeze), a built-in ISF file
//            (Colour, Transform, Echo), and every ISF file the operator imported or
//            shares with other apps. Each is a `ModuleDescriptor`: a name, where it
//            came from, the controls its card shows, and a factory for its node. The
//            FX panel builds every card from these, the same way (ISF-PLAN M7), and
//            the Add menu lists them.
//  Inputs  : the ISF folders (ISFLibrary), feature flags, a Metal context.
//  Outputs : `[ModuleDescriptor]`, and nodes on request.
//  Connects: EffectChain (instances refer to descriptors by `id`), Engine (makes the
//            nodes), the FX panel (cards and the Add menu), ISFLibrary (scans).
//  Extend  : a native module is one entry in `nativeModules` — name, controls,
//            factory. An ISF module needs nothing here: drop the file in a folder.
//
//  ISF effects only in the chain. ISF generators become sources (the Asset Browser's
//  Generators tab) and ISF transitions become crossfader transitions (`transitions`).
//

import Foundation
import Metal

/// How a card's control reads, beyond "a number".
public enum ModuleControlKind: Equatable, Sendable {
    case continuous
    /// On above halfway.
    case toggle
    /// Steps through labelled choices.
    case choice
    /// Fires as it crosses halfway.
    case trigger
}

/// How a trigger is armed to fire on the beat by itself: another control on the
/// same card, a choice of how often, that the node already fires the trigger on.
///
/// Option-Command-click on the trigger's key flips that choice between off (its
/// FIRST position, which must mean off) and a rate — the gesture that arms CUT and
/// FADE to tap on the beat — so there is ONE
/// beat state per trigger, and it is timed by the node on the frame's own musical
/// position rather than by the UI's clock.
public struct ModuleBeatArm {
    /// The choice that fires the trigger on the beat ("heal every").
    public let code: ParamCode
    /// What arming sets it to when it has not been armed before, in its own units.
    public let armedValue: Double
    /// Whether a value of the choice (its own units) means "firing on the beat".
    public let isArmed: (Double) -> Bool

    public init(code: ParamCode, armedValue: Double, isArmed: @escaping (Double) -> Bool) {
        self.code = code
        self.armedValue = armedValue
        self.isArmed = isArmed
    }
}

/// One fader on a card.
public struct ModuleControl {
    public let label: String
    public let code: ParamCode
    public let kind: ModuleControlKind
    /// What the readout says for a value in the parameter's own units.
    public let valueText: (Double) -> String
    /// For a trigger that can be armed on the beat, how. Nil for everything else.
    public let beatArm: ModuleBeatArm?
    /// What the control does, in a sentence or two — the card's tooltip for it. A
    /// one-word label cannot say "only works while bloom is up".
    public let help: String?

    public init(label: String, code: ParamCode, kind: ModuleControlKind = .continuous,
                valueText: @escaping (Double) -> String = { String(format: "%.2f", $0) },
                beatArm: ModuleBeatArm? = nil, help: String? = nil) {
        self.label = label
        self.code = code
        self.kind = kind
        self.valueText = valueText
        self.beatArm = beatArm
        self.help = help
    }
}

/// Where a module came from, which is what its card's badge says.
public enum ModuleOrigin: String, Equatable, Sendable {
    /// Written in Swift/Metal: the bitstream, capture and signal-path modules.
    case native
    /// An ISF file that ships inside Videoboy.
    case builtin
    /// An ISF file the operator imported (Videoboy's own folder).
    case imported
    /// An ISF file in the shared ~/Library/Graphics/ISF folder.
    case shared

    /// The badge on the card.
    public var badge: String {
        switch self {
        case .native, .builtin: "built-in"
        case .imported, .shared: "ISF"
        }
    }
}

/// Everything the app needs to know about one module.
public struct ModuleDescriptor {
    public let id: String
    /// The card's title. Unique among descriptors.
    public let name: String
    public let origin: ModuleOrigin
    /// The Add menu's group: "Built-in", or the ISF file's first category.
    public let group: String
    public let controls: [ModuleControl]
    /// Why this module cannot be added (a file that does not parse, a feature that
    /// is switched off). Shown in the Add menu, greyed, as the tooltip.
    public let problem: String?
    /// For an ISF module: its file, so hot reload can find the instances to refresh.
    public let fileURL: URL?
    let factory: (String, MetalContext?) -> Node

    public var isAvailable: Bool { problem == nil }

    /// Makes one node of this module under a slot name.
    public func makeNode(identifier: String, context: MetalContext?) -> Node {
        factory(identifier, context)
    }
}

/// The modules a chain can hold.
public final class ModuleCatalog {

    /// Stable IDs for the modules the default chain and the templates refer to.
    public enum ID {
        public static let datamosh = "native.datamosh"
        public static let composite = "native.composite"
        public static let feedback = "native.feedback"
        public static let freeze = "native.freeze"
        public static let transform = "builtin.Transform"
        public static let colour = "builtin.Colour"
        public static let echo = "builtin.Echo"

        /// An ISF module's ID, from its file name.
        public static func isf(_ name: String) -> String { "isf.\(name)" }
    }

    /// Every module, natives and built-ins first, then ISF files by name.
    public private(set) var modules: [ModuleDescriptor] = []
    /// ISF files that were found but cannot be offered (they failed, or are not
    /// effects), for the Add menu's "Failed to load" group.
    public private(set) var unavailable: [ModuleDescriptor] = []
    /// ISF GENERATORS — files with no image input. Sources, not chain effects: the
    /// Asset Browser's Generators tab and each channel's source menu offer them
    /// (ISF-PLAN M9). Their factory makes an ISFNode that renders at project size.
    public private(set) var generators: [ModuleDescriptor] = []
    /// ISF transitions (startImage, endImage, progress), for the crossfaders'
    /// transition key — not effects, and not sources.
    public private(set) var transitions: [ModuleDescriptor] = []

    /// Where ISF modules are looked for, in precedence order.
    public let folders: [(URL, ISFLibraryEntry.Folder)]

    /// - Parameter folders: where to look for ISF files. Defaults to the three
    ///   standard folders; the self-QA points it at temporary ones.
    public init(folders: [(URL, ISFLibraryEntry.Folder)] = ISFLibrary.standardFolders) {
        self.folders = folders
        refresh()
    }

    /// Looks up a module by ID.
    public func module(_ id: String) -> ModuleDescriptor? {
        modules.first { $0.id == id } ?? unavailable.first { $0.id == id }
    }

    /// Rescans the ISF folders. File reads: callers on the render thread's queue
    /// should prefer `refresh(with:)` with entries scanned elsewhere.
    public func refresh() {
        refresh(with: ISFLibrary.scan(folders))
    }

    /// Rebuilds the list from already-scanned library entries.
    public func refresh(with entries: [ISFLibraryEntry]) {
        var available = ModuleCatalog.nativeModules()
        var failed: [ModuleDescriptor] = []
        var sources: [ModuleDescriptor] = []
        var fades: [ModuleDescriptor] = []
        let builtinNames: [String: (id: String, title: String)] = [
            "Transform": (ID.transform, "Transform"),
            "Colour": (ID.colour, "Colour"),
            "Echo": (ID.echo, "Echo / Trails")
        ]
        for entry in entries {
            let isBuiltinPort = entry.folder == .builtin && builtinNames[entry.name] != nil
            let id = isBuiltinPort ? builtinNames[entry.name]!.id : ID.isf(entry.name)
            let title = isBuiltinPort ? builtinNames[entry.name]!.title : entry.name
            let origin: ModuleOrigin = switch entry.folder {
            case .builtin: .builtin
            case .user: .imported
            case .shared: .shared
            }
            switch entry.result {
            case .failure(let error):
                failed.append(ModuleCatalog.isfDescriptor(
                    id: id, title: title, origin: origin, document: nil, entry: entry,
                    problem: error.description))
            case .success(let document):
                if document.kind == .generator {
                    sources.append(ModuleCatalog.isfDescriptor(
                        id: id, title: title, origin: origin, document: document, entry: entry, problem: nil))
                    continue
                }
                if document.kind == .transition {
                    fades.append(ModuleCatalog.isfDescriptor(
                        id: id, title: title, origin: origin, document: document, entry: entry, problem: nil))
                    continue
                }
                guard document.kind == .effect else { continue }
                let descriptor = ModuleCatalog.isfDescriptor(
                    id: id, title: title, origin: origin, document: document, entry: entry, problem: nil)
                available.append(descriptor)
            }
        }
        // Natives, then built-in ports, then everything else by name.
        let rank: (ModuleDescriptor) -> Int = { $0.origin == .native ? 0 : ($0.origin == .builtin ? 1 : 2) }
        modules = available.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        unavailable = failed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        generators = sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        transitions = fades.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Looks up an ISF transition by ID.
    public func transition(_ id: String) -> ModuleDescriptor? {
        transitions.first { $0.id == id }
    }

    /// Looks up an ISF generator by ID.
    public func generator(_ id: String) -> ModuleDescriptor? {
        generators.first { $0.id == id }
    }

    // MARK: - ISF modules

    private static func isfDescriptor(
        id: String, title: String, origin: ModuleOrigin, document: ISFDocument?,
        entry: ISFLibraryEntry, problem: String?
    ) -> ModuleDescriptor {
        let controls = (document.map(ISFControl.controls(for:)) ?? []).map { control -> ModuleControl in
            let kind: ModuleControlKind
            switch control.type {
            case .bool: kind = .toggle
            case .long: kind = .choice
            case .event: kind = .trigger
            default: kind = .continuous
            }
            return ModuleControl(label: control.label, code: control.code, kind: kind,
                                 valueText: { control.valueText($0) })
        }
        let group: String
        if origin == .builtin || origin == .native {
            group = "Built-in"
        } else {
            group = document?.categories.first { $0 != "Videoboy" } ?? "ISF"
        }
        let source = entry.source ?? ""
        let vertexSource = entry.vertexSource
        let directory = entry.url.deletingLastPathComponent()
        let name = entry.name
        return ModuleDescriptor(
            id: id, name: title, origin: origin, group: group, controls: controls,
            problem: problem, fileURL: entry.url,
            factory: { identifier, context in
                let node = ISFNode(identifier: identifier, context: context)
                node.load(source: source, vertexSource: vertexSource, name: name,
                          resourceDirectory: directory)
                return node
            })
    }

    // MARK: - Native modules

    /// The modules written in Swift/Metal. Controls are listed in card order.
    static func nativeModules() -> [ModuleDescriptor] {
        func number(_ value: Double) -> String { String(format: "%.2f", value) }
        return [
            ModuleDescriptor(
                id: ID.datamosh, name: "Datamosh · H.264", origin: .native, group: "Built-in",
                // Order is the card's, unchanged since the performer learned it; the
                // names, readouts and tooltips were reviewed with the owner 2026-09-28
                // ("I can't tell what some of them even do").
                controls: [
                    ModuleControl(label: "mosh", code: .moshAmount,
                                  valueText: { $0 > 0.001 ? number($0) : "off" },
                                  help: "Drops the frames where the picture changes a lot — cuts, big moves — so "
                                    + "the new motion smears across the old picture. Higher catches smaller "
                                    + "changes. Needs a cut or movement to show; a still picture stays still."),
                    ModuleControl(label: "melt", code: .moshMelt,
                                  valueText: { value in
                                      // The drop rate MoshEngine uses: melt² × 0.35.
                                      let chance = min(max(value, 0), 1) * min(max(value, 0), 1) * 0.35
                                      guard chance > 0.00001 else { return "off" }
                                      let oneIn = Int((1 / chance).rounded())
                                      return oneIn > 99 ? "rare" : "1/\(oneIn)"
                                  },
                                  help: "Drops ordinary frames at random, so the smear builds even on continuous "
                                    + "footage with no cut. The readout is how many frames go: 1/3 at the top."),
                    ModuleControl(label: "bloom", code: .moshBloom,
                                  valueText: { $0 > 0.001 ? "\(Int(($0 * 100).rounded()))%" : "off" },
                                  help: "Replays the last few frames' motion in a loop, so the picture streams "
                                    + "outward. The readout is the share of frames that are replays: 100% "
                                    + "streams nonstop, 50% lets live motion through between replays."),
                    ModuleControl(label: "bloom loop", code: .moshLoop,
                                  valueText: { "\(MoshControls.bloomLength(fromNormalised: $0))fr" },
                                  help: "How many recent frames bloom repeats, 1 to 16. Only does anything while "
                                    + "bloom is up."),
                    ModuleControl(label: "bitrate", code: .moshBlocks,
                                  valueText: { String(format: "%.1fM", H264LiveEncoder.bitRate(forNormalised: $0) / 1_000_000) },
                                  help: "The encoder's bitrate, 0.4 to 8 Mb/s. Down starves it: big blocks and "
                                    + "smeared colour, and the mosh breaks up coarser. Up is clean."),
                    // Two keys, one row (adjacent triggers share one — see the FX
                    // panel): HOLD, held for full mosh and bloom, then HEAL. HOLD was
                    // labelled "mosh", the same as the fader above it, doing something else.
                    ModuleControl(label: "hold", code: .moshHold, kind: .trigger,
                                  valueText: { $0 >= 0.5 ? "hold" : "—" },
                                  help: "Hold for everything at once: full mosh and full bloom, streaming the "
                                    + "bloom loop. Let go and the faders are back in charge."),
                    // Option-Command-click HEAL arms "heal every" at one beat (or the
                    // rate it last had), and again turns it off.
                    ModuleControl(label: "heal", code: .moshHeal, kind: .trigger,
                                  valueText: { $0 >= 0.5 ? "heal" : "—" },
                                  beatArm: ModuleBeatArm(
                                    code: .moshHealEvery,
                                    armedValue: MoshHealEvery.beat.normalisedPosition,
                                    isArmed: { MoshHealEvery.from(normalised: $0) != .off }),
                                  help: "Brings the clean picture back over the heal time; the mosh then carries "
                                    + "on from it. Option-Command-click heals on the beat."),
                    ModuleControl(label: "heal every", code: .moshHealEvery, kind: .choice,
                                  valueText: { MoshHealEvery.from(normalised: $0).shortName },
                                  help: "Heals by itself on the beat, from every 1/16 to every 4 bars, while the "
                                    + "transport is running."),
                    ModuleControl(label: "heal time", code: .moshHealTime,
                                  valueText: { value in
                                      let frames = MoshHealEnvelope.frames(fromNormalised: value)
                                      return frames == 0
                                          ? "now"
                                          : String(format: "%.2fs", Double(frames) / StandardDefinition.frameRate)
                                  },
                                  help: "How long a heal takes to bring the clean picture back — and how long "
                                    + "letting go of the card takes to fade the mosh out."),
                    ModuleControl(label: "heal shape", code: .moshHealShape, kind: .choice,
                                  valueText: { MoshHealShape.from(normalised: $0).displayName },
                                  help: "How the clean picture comes back during a heal: a fade, blocks snapping "
                                    + "back at random, a wipe from the top, or the brightest parts first."),
                    ModuleControl(label: "opacity", code: .opacity,
                                  help: "How strongly the mosh lies over the clean picture."),
                    ModuleControl(label: "blend", code: .moshBlend, kind: .choice,
                                  valueText: { DatamoshNode.blendShortName(DatamoshNode.blendMode(fromNormalised: $0)) },
                                  help: "How the mosh combines with the clean picture — normal, screen, "
                                    + "difference and the rest.")
                ],
                problem: nil, fileURL: nil,
                factory: { DatamoshNode(identifier: $0, context: $1) }),
            ModuleDescriptor(
                id: ID.composite, name: "Composite · NTSC", origin: .native, group: "Built-in",
                controls: [
                    ModuleControl(label: "path", code: .compositePath),
                    ModuleControl(label: "crawl", code: .compositeCrawl),
                    ModuleControl(label: "bleed", code: .chromaBleed),
                    ModuleControl(label: "luma bw", code: .lumaBandwidth),
                    ModuleControl(label: "wobble", code: .tbcWobble),
                    ModuleControl(label: "head sw", code: .headSwitchingNoise),
                    ModuleControl(label: "chroma", code: .chromaSubsampling),
                    ModuleControl(label: "gen", code: .compositeGeneration)
                ],
                problem: FeatureFlag.compositeCodec.isOn ? nil : "switched off (FeatureFlag.compositeCodec)",
                fileURL: nil,
                factory: { CompositeCodecNode(identifier: $0, context: $1) }),
            ModuleDescriptor(
                id: ID.feedback, name: "Feedback", origin: .native, group: "Built-in",
                controls: [
                    ModuleControl(label: "gain", code: .feedbackGain),
                    ModuleControl(label: "delay", code: .feedbackDelayFrames),
                    ModuleControl(label: "zoom", code: .feedbackZoom),
                    ModuleControl(label: "rotate", code: .feedbackRotate)
                ],
                problem: FeatureFlag.feedback.isOn ? nil : "switched off (FeatureFlag.feedback)",
                fileURL: nil,
                factory: { FeedbackNode(identifier: $0, context: $1) }),
            ModuleDescriptor(
                id: ID.freeze, name: "Freeze", origin: .native, group: "Built-in",
                controls: [
                    ModuleControl(label: "hold", code: .freezeHold, kind: .toggle,
                                  valueText: { $0 > 0.5 ? "held" : "live" })
                ],
                problem: nil, fileURL: nil,
                factory: { FreezeNode(identifier: $0, context: $1) })
        ]
    }
}
