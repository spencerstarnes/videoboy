//
//  EmulatedTitlerNode.swift — the emulator, as a source in the graph.
//
//  Purpose : Presents whatever the emulated machine is showing as an ordinary video
//            source, so it can be assigned to a channel and overlaid on the programme
//            like anything else. Becoming a source is the whole point — running the
//            software is not useful until its output is routable.
//  Inputs  : none. It produces.
//  Outputs : one texture per frame, from the host's framebuffer.
//  Connects: EmulatorHost (out of process, for licensing — see EmulatedTitler.swift),
//            the render graph, the EMU tab.
//  Extend  : this deliberately knows nothing about WHICH program is running. That is
//            the host's business, and keeping it that way is what lets the panel
//            switch software without the graph noticing.
//

import Foundation
import Metal

/// A running emulator, as a graph source.
public final class EmulatedTitlerNode: Node {

    public let identifier: String
    public let kind: NodeKind = .source
    public var latencyInFrames: Int { 0 }

    /// The emulator behind this source. Swappable so the panel can run against a mock
    /// while no core is installed, without the graph knowing the difference.
    public var host: EmulatorHost

    private let context: MetalContext?
    private var texture: MTLTexture?
    /// The frame already uploaded, so an emulator running slower than the render loop
    /// does not cost an upload per render for a picture that has not changed.
    private var uploadedFrameIsCurrent = false

    public init(
        identifier: String,
        host: EmulatorHost,
        context: MetalContext? = MetalContext.shared
    ) {
        self.identifier = identifier
        self.host = host
        self.context = context
    }

    public var parameters: [Parameter] {
        [Parameter(code: .opacity, range: 0...1, defaultValue: 1)]
    }

    public func applyParameters(from registry: ParamRegistry) {}

    /// Whether this source has anything to show, for the greyed-out state.
    public var isRunning: Bool { host.isReady && host.latestFrame() != nil }

    /// Boots a program and starts producing frames.
    @discardableResult
    public func boot(_ program: TitlerProgram) -> Bool {
        uploadedFrameIsCurrent = false
        let started = host.boot(program)
        Log.info(.titler, started
            ? "\(identifier) booted \(program.name)"
            : "\(identifier) could not boot \(program.name): \(host.unavailableReason ?? "unknown")")
        return started
    }

    /// Sends text to the running program, one step per character.
    ///
    /// Per character because that is what the software is expecting — it was written
    /// for a keyboard, and there is no API underneath it to hand a whole string to.
    public func type(_ text: String) {
        guard host.isReady else { return }
        host.send(.type(text))
    }

    /// Sends a single control press: a function key, return, escape.
    public func press(_ key: String) {
        guard host.isReady else { return }
        host.send(.key(key))
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return nil }
        // Nothing running is not an error — it is the state this is in on any machine
        // without a core, and it must render as an empty source rather than a crash.
        guard let frame = host.latestFrame() else { return nil }

        if uploadedFrameIsCurrent, let texture { return texture }
        texture = metal.makeTexture(from: frame, label: identifier)
        uploadedFrameIsCurrent = true
        return texture
    }

    /// Called when the emulator reports a new frame, so the next render uploads it.
    public func invalidateFrame() {
        uploadedFrameIsCurrent = false
    }
}
