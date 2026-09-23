//
//  FreezeNode.swift — hold the picture (SPEC 9's freeze, kept when MX-1 went).
//
//  Purpose : A performance gesture: push HOLD and the picture stops while everything
//            upstream keeps running; let go and it is live again. The rest of the
//            MX-1 set was removed (owner decision, 2026-09-23 — ISF-PLAN §4.1);
//            freeze stayed because it is something you DO mid-set, not a look.
//  Inputs  : one texture.
//  Outputs : the input, or the frame that was on screen when HOLD went up.
//  Connects: the "Freeze" card (native module), codes 02A wet/dry and 24A hold.
//  Extend  : a "hold for N beats" would be a second parameter and a counter here.
//
//  Not a shader: holding a frame is a choice of WHICH texture to hand on. The frame
//  is COPIED into a texture this node owns — upstream nodes redraw into the same
//  texture every frame, so holding a reference would hold nothing at all. The copy
//  target is allocated once and reused; engaging costs one blit.
//

import Foundation
import Metal

/// Holds the current frame while `hold` is up.
public final class FreezeNode: Node, ParameterApplying {

    public let identifier: String
    public let kind: NodeKind = .effect
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .freezeHold, range: 0...1, defaultValue: 0)
        ]
    }

    /// 0 bypasses (and lets go of any held frame).
    public var wetDry = 1.0
    /// Above 0.5 the picture is held. A MIDI pad or a key maps straight onto it.
    public var hold = 0.0

    /// Whether a frame is being held right now. For the self-QA and the overlay.
    public private(set) var isHolding = false

    private let context: MetalContext?
    /// The held frame. Kept between holds so engaging again reuses it.
    private var held: MTLTexture?

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let input = inputs.first else { return nil }
        guard wetDry > 0.001, hold > 0.5, let metal = context else {
            isHolding = false
            return input
        }
        if !isHolding {
            // The moment HOLD goes up: copy what is on screen now.
            if held?.width != input.width || held?.height != input.height {
                held = metal.makeRenderTarget(width: input.width, height: input.height, label: "\(identifier)-held")
            }
            guard let held, let commandBuffer = metal.commandQueue.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else { return input }
            blit.copy(from: input, to: held)
            blit.endEncoding()
            metal.submit(commandBuffer, label: "\(identifier) hold")
            isHolding = true
        }
        return held ?? input
    }

    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        if let value = registry.value(slot: identifier, code: .freezeHold) { hold = value }
    }
}
