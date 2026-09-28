//
//  ExampleNode.swift — the canonical copy-me module (SPEC 1.5).
//
//  Named Example rather than Template because "template" already means a saved
//  setup in this app (SPEC 16), and one word for two unrelated things is how a
//  codebase starts lying to you.
//
//  Purpose : The starting point for every new source, effect or output. Copy this
//            folder, rename the type, fill in the four marked places, and the node
//            works with the graph, the param registry, MIDI, the LFOs, audio
//            reactivity and templates — all of it, without further wiring.
//  Inputs  : whatever the graph's edges feed it (none, for a source).
//  Outputs : one texture.
//  Connects: the `Node` protocol, which is the app's ONE extension point.
//  Extend  : see docs/ADD-A-MODULE.md for the recipe.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE FOUR THINGS TO FILL IN
//
//    1. `kind`        — source, effect, mix or output.
//    2. `parameters`  — what this node exposes, by STABLE param code (SPEC 13).
//                       Reuse an existing code wherever the parameter is a common
//                       one: opacity is always 01A, scale always 11A. Only invent
//                       a code for something genuinely specific to this module, and
//                       never reuse a retired one.
//    3. `latencyInFrames` — how long this node takes to make a visible result. The
//                       scheduler compensates with it, so a beat-synced change lands
//                       on the beat. Return 0 if the work completes within a frame.
//    4. `render`      — do the work, return a texture.
//
//  And one more, by convention rather than by protocol: `applyParameters(from:)`,
//  which pulls values out of the registry. Every node has it, because that is how a
//  MIDI knob, an LFO, an audio tap and a loaded template all reach a node by exactly
//  the same route.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Metal

/// A do-nothing node, kept as the shape every other node follows.
///
/// It passes its input straight through. Copy it, do not edit it — it is here to be
/// read by whoever writes the next module, and it should stay boring.
public final class ExampleNode: Node {

    // MARK: Identity

    /// Stable identifier. Doubles as the mapping slot name and the template key, so
    /// it must not change across a save and load.
    public let identifier: String

    // (1) What kind of node this is.
    public let kind: NodeKind = .effect

    // (3) How long this node takes to produce a visible result, in frames.
    public let latencyInFrames = 0

    // (2) What this node exposes. Codes come from `ParamCode`.
    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1)
        ]
    }

    // MARK: State

    /// 0 bypasses the node entirely, 1 applies it fully.
    public var wetDry = 1.0

    /// The shared Metal state. Optional throughout: a machine with no Metal device
    /// must still launch, with this node degrading to a pass-through rather than
    /// crashing (SPEC 1.5, fail visibly and never fatally).
    private let context: MetalContext?

    /// Reused across frames. Allocating a target per frame in the render loop is
    /// forbidden (SPEC 1).
    private var target: MTLTexture?

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    // MARK: (4) The work

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let input = inputs.first else { return nil }

        // Fully dry costs nothing — skip the work rather than doing it and then
        // blending none of it in.
        guard wetDry > 0.001, let metal = context else { return input }

        if target == nil || target?.width != input.width || target?.height != input.height {
            target = metal.makeRenderTarget(
                width: input.width, height: input.height, label: identifier)
        }
        guard let target else { return input }

        // Replace this pass with the real work. The blit pipeline copies the input
        // unchanged, which is what makes this template a pass-through.
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            // Never swallow this. A missing encoder means nothing will be drawn, and
            // silence would look like the effect simply not working (SPEC 1.5).
            Log.error(.render, "\(identifier) could not encode its pass")
            return input
        }
        encoder.setRenderPipelineState(metal.blitPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) pass failed: \(error)")
            return input
        }

        guard wetDry < 0.999 else { return target }
        // The shared wet/dry blend, so this node's Wet/Dry behaves like every other's.
        return metal.blend(dry: input, wet: target, amount: wetDry, into: target, label: identifier)
            ? target : input
    }

    // MARK: Parameters

    /// Pulls this node's values out of the registry.
    ///
    /// Called once per frame by the engine, before the graph is evaluated. Read every
    /// parameter this node declares; a parameter declared and never read is a control
    /// that appears in the interface and does nothing.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
    }
}
