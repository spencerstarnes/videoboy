//
//  GeneratorThumbnails.swift — a still picture of every generator, for the library.
//
//  Purpose : The Generators tab's tiles. A clip's thumbnail is decoded from its file;
//            a generator has no file, so its picture is rendered — once — through the
//            same node and shader the channel will run, at thumbnail size.
//  Inputs  : a `GeneratorKind`, or an ISF generator's `ModuleDescriptor`.
//  Outputs : `NSImage`s, cached by generator.
//  Connects: GeneratorSourceNode, ISFNode (via ModuleDescriptor.makeNode),
//            OffscreenRenderer.readback; read by LibraryPanelBody and ShellController.
//  Extend  : a new generator kind needs nothing here — it is rendered like the rest.
//
//  Never on the frame path: each picture is rendered the first time a tab asks for
//  it, and then only again when an ISF file changes on disk.
//

import AppKit
import VideoboyCore

/// Renders and caches one still per generator.
final class GeneratorThumbnails {

    static let shared = GeneratorThumbnails()

    /// Thumbnail geometry: 4:3, like everything else in an SD graph, and small —
    /// a tile is under 100 points wide.
    private static let width = 160
    private static let height = 120
    /// How far into its animation a generator is caught. Frame 0 is the least
    /// representative moment for most of them — phase 0 is a plain ramp's start.
    private static let stillFrame = 45
    private static let stillPhase = 0.25
    /// How long an ISF file may take to compile before its tile is left blank.
    private static let compileTimeout: TimeInterval = 10

    private var builtIn: [GeneratorKind: NSImage] = [:]
    private var isf: [String: NSImage] = [:]
    /// ISF generators compiling in the background, by module ID.
    private var pending: [String: (node: ISFNode, started: Date)] = [:]
    private var pollTimer: Timer?

    /// Called on main when an ISF picture becomes available, so the tiles can be rebuilt.
    var onISFUpdated: (() -> Void)?

    private lazy var renderer = OffscreenRenderer()

    private var context: RenderContext {
        RenderContext(
            frameIndex: Self.stillFrame,
            presentationTime: Double(Self.stillFrame) / 29.97,
            musicalPosition: nil,
            width: Self.width, height: Self.height)
    }

    /// The picture of a built-in generator, rendered on first request.
    func image(for kind: GeneratorKind) -> NSImage? {
        if let cached = builtIn[kind] { return cached }
        let node = GeneratorSourceNode(identifier: "thumbnail.\(kind)")
        node.generator = kind
        node.phase = Self.stillPhase
        guard let image = render(node) else {
            Log.warn(.render, "no thumbnail for generator \(kind.displayName)")
            return nil
        }
        builtIn[kind] = image
        return image
    }

    /// The picture of an ISF generator, or nil while it compiles. `onISFUpdated`
    /// fires once it is ready.
    func image(for module: ModuleDescriptor) -> NSImage? {
        if let cached = isf[module.id] { return cached }
        guard pending[module.id] == nil else { return nil }
        guard let node = module.makeNode(
            identifier: "thumbnail.\(module.id)", context: MetalContext.shared) as? ISFNode else {
            Log.warn(.isf, "no thumbnail for \(module.name): not an ISF node")
            return nil
        }
        pending[module.id] = (node, Date())
        startPolling()
        return nil
    }

    /// Drops the ISF pictures, so a changed file is re-rendered.
    func forgetISF() {
        isf.removeAll()
        pending.removeAll()
    }

    // MARK: - Rendering

    private func render(_ node: Node) -> NSImage? {
        guard let texture = node.render(inputs: [], context: context),
              let buffer = renderer?.readback(texture),
              let cgImage = buffer.makeCGImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: buffer.width, height: buffer.height))
    }

    /// Checks the compiling ISF nodes a few times a second until none are left.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollPending()
        }
    }

    private func pollPending() {
        var rendered = false
        for (id, entry) in pending {
            switch entry.node.state {
            case .ready:
                pending[id] = nil
                if let image = render(entry.node) {
                    isf[id] = image
                    rendered = true
                }
            case .compiling where Date().timeIntervalSince(entry.started) < Self.compileTimeout:
                continue
            default:
                Log.warn(.isf, "no thumbnail for \(id): it did not compile")
                pending[id] = nil
            }
        }
        if pending.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        if rendered { onISFUpdated?() }
    }
}
