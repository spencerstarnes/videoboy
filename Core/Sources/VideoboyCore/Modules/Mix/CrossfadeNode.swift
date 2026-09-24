//
//  CrossfadeNode.swift — the two-input layer compositor used for every bus (SPEC 12).
//
//  Purpose : ONE is A over B, TWO is C over D, PRIMARY is ONE over TWO. All three
//            are this same node, which is why the routing can be fixed and the
//            behaviour identical everywhere.
//  Inputs  : two textures (slot 0 is the left/"A" side, slot 1 the right/"B" side).
//  Outputs : the mixed texture.
//  Connects: MetalContext's crossfade pipeline — the same one the self-QA harness
//            uses, so an offscreen check and the live output cannot diverge.
//  Extend  : a new blend mode is a case in `BlendMode` plus a branch in the shader;
//            a new wipe is a case in `Transition` plus a branch in `transitionMask`.
//            Either way the node does not change, and it is still ONE draw.
//            (The AVE-5 transition is the exception that proves it: its block state
//            rides in the same parameter block and it is still the same one draw.)
//
//  Parameters (SPEC 13): one of 61A / 62A / 63A depending on which bus this is,
//  plus 65A blend mode, 66A layer opacity, 61F transition pattern, and 6xE (61E/62E/63E) for the key
//  colour/threshold/edge — read and sent every frame like the others, but only
//  acted on by the shader when blendMode is `.key`. 62F–69F are the AVE-5 wipe
//  block's state and 61G–6AG its momentary key presses (ShellController consumes
//  those); both only matter when the transition is AVE-5.
//

import Foundation
import Metal

/// The parameter block handed to the blend shader. Layout must match `BlendParams`
/// in the Metal source exactly.
private struct BlendParams {
    var mixAmount: Float
    var opacity: Float
    var mode: Int32
    var keyR: Float
    var keyG: Float
    var keyB: Float
    var keyThreshold: Float
    var keyEdge: Float
    var transition: Int32
    // AVE-5 wipe block (only read when transition is AVE-5). All 4-byte scalars, in
    // the same order as the Metal struct, so the two layouts cannot drift.
    var ave5Keys: Int32
    var ave5Tiles: Int32
    var ave5Edge: Int32
    var ave5Reversed: Int32
    var ave5CentreX: Float
    var ave5CentreY: Float
    var ave5BorderR: Float
    var ave5BorderG: Float
    var ave5BorderB: Float
}

/// Mixes two inputs by a single position parameter.
public final class CrossfadeNode: Node {

    public let identifier: String
    public let kind: NodeKind = .mix
    /// A GPU blend of two ready textures completes within the frame it starts.
    public let latencyInFrames = 0

    /// Which crossfade parameter this instance owns.
    public let positionCode: ParamCode

    public var parameters: [Parameter] {
        [
            Parameter(code: positionCode, range: 0...1, defaultValue: 0.5),
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .blendMode, range: 0...1, defaultValue: 0),
            Parameter(code: .layerOpacity, range: 0...1, defaultValue: 1),
            // Defaults key on black with a modest, usable threshold/edge out of the
            // box — SPEC 18.2's "colour 0 = transparent" case — so switching a
            // composite to Key mode does something reasonable before anyone has
            // touched these three at all.
            Parameter(code: .keyColour, range: 0...1, defaultValue: 0),
            Parameter(code: .keyThreshold, range: 0...1, defaultValue: 0.25),
            Parameter(code: .keyEdge, range: 0...1, defaultValue: 0.2),
            // Momentary triggers (SPEC 7): a MIDI button writes 1, ShellController
            // reads it once and puts it back to 0. They have to be registered here
            // like any other parameter or `ParamRegistry.deliver` has nowhere to
            // land the value — a learned button would show "mapped" in the log and
            // then never actually fire.
            Parameter(code: .cutTrigger, range: 0...1, defaultValue: 0),
            Parameter(code: .fadeTrigger, range: 0...1, defaultValue: 0),
            Parameter(code: .cutToLeftTrigger, range: 0...1, defaultValue: 0),
            Parameter(code: .cutToRightTrigger, range: 0...1, defaultValue: 0),
            Parameter(code: .transition, range: 0...1, defaultValue: 0)
        ] + AVE5Wipe.parameters + AVE5Wipe.triggerParameters
    }

    /// 0 is entirely input 0, 1 is entirely input 1.
    public var position: Double = 0.5

    /// How the upper layer combines with the lower one.
    public var blendMode: BlendMode = .normal

    /// Which pattern the fader's travel follows. Dissolve is what it always did.
    public var transition: Transition = .dissolve

    /// An ISF transition to draw the move with instead of `transition`, or nil.
    /// While it compiles, the ordinary transition stands in, so choosing one never
    /// blanks the mix.
    public var isfTransition: ISFNode?

    /// The AVE-5 wipe block's state, used when `transition` is `.ave5`.
    public var ave5 = AVE5Wipe()

    /// ONE-WAY's memory of which way the lever last travelled end to end.
    ///
    /// Latched at the ENDS, not on every change of direction: the hardware keeps
    /// the wipe's direction for the trip back from B, and a hand that wobbles
    /// mid-travel should retrace the edge, not flip the pattern under it. True once
    /// the fader has reached B, false once it has reached A.
    private(set) var isReturningFromB = false

    /// Whether the AVE-5 pattern is drawn reversed this frame: REVERSE, flipped
    /// again by ONE-WAY on the trip back. ONE-WAY's return trip IS a reverse wipe
    /// — B leaves by the edge it came in from — so the two compose as an XOR.
    public var ave5DrawsReversed: Bool {
        ave5.reverse != (ave5.oneWay && isReturningFromB)
    }

    /// Updates the ONE-WAY latch from the fader position. Called once per render.
    func updateOneWayLatch() {
        // Within half a percent of an end counts as reaching it: a MIDI fader's
        // top value is 127/127 but a hand-dragged one can stop a hair short.
        if position >= 0.995 {
            isReturningFromB = true
        } else if position <= 0.005 {
            isReturningFromB = false
        }
    }
    /// Per-layer opacity of the upper layer.
    public var layerOpacity: Double = 1.0

    /// Raw 0...1 key-colour parameter (6xE `.keyColour`). Converted to RGB by
    /// `keyRGB` at render time, not stored as RGB directly, so it round-trips
    /// through templates and MIDI mappings the same single-fader way every other
    /// colour control in this app does.
    public var keyColourValue: Double = 0
    /// RGB distance below which a pixel counts as the key colour. Real units
    /// (0...1 per channel, so 0...~1.73 is the full range of `length()` between two
    /// RGB triples); the 0...1 param is scaled down in `render` because the useful
    /// range for a key is a small fraction of that.
    public var keyThreshold: Double = 0.25
    /// Width of the soft edge past `keyThreshold`, same units and same scaling.
    public var keyEdge: Double = 0.2

    /// The key colour as RGB, from the raw 0...1 parameter.
    ///
    /// Zero is pinned to TRUE BLACK rather than fed through the hue sweep, which
    /// would otherwise put red at the fader's rest position (`ScalaColour.hue(0)`
    /// is red — see `Modules/Emu/ScalaLingo.swift`). Keying on red by default,
    /// when "key out black" is the overwhelmingly common case (an Amiga's colour 0,
    /// and most genlock hardware besides), would make every new Key composite
    /// start by keying on the wrong colour until someone found and moved this
    /// fader. Above zero it sweeps hue at full saturation, same as everywhere else
    /// in this app a single fader stands in for a colour.
    static func keyRGB(_ value: Double) -> (r: Double, g: Double, b: Double) {
        guard value > 0 else { return (0, 0, 0) }
        let hue = min(max(value, 0), 1) * 6
        let sector = Int(hue) % 6
        let rising = hue - Double(Int(hue))
        let falling = 1 - rising
        switch sector {
        case 0: return (1, rising, 0)
        case 1: return (falling, 1, 0)
        case 2: return (0, 1, rising)
        case 3: return (0, falling, 1)
        case 4: return (rising, 0, 1)
        default: return (1, 0, falling)
        }
    }

    private let context: MetalContext?
    private var target: MTLTexture?

    public init(identifier: String, positionCode: ParamCode, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.positionCode = positionCode
        self.context = context
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return nil }

        // With only one input connected there is nothing to mix; pass it through.
        // This is what makes a half-built graph still show a picture.
        guard inputs.count >= 2 else { return inputs.first }
        let sourceA = inputs[0]
        let sourceB = inputs[1]

        if let isfTransition,
           let drawn = isfTransition.renderTransition(
            start: sourceA, end: sourceB, progress: position, context: renderContext) {
            return drawn
        }

        // Reuse the render target across frames: SPEC 1 forbids per-frame allocation
        // in the render loop.
        if target == nil || target?.width != renderContext.width || target?.height != renderContext.height {
            target = metal.makeRenderTarget(
                width: renderContext.width, height: renderContext.height, label: identifier)
        }
        guard let target else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its crossfade")
            return target
        }
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.blendPipeline)
        encoder.setFragmentTexture(sourceA, index: 0)
        encoder.setFragmentTexture(sourceB, index: 1)
        let key = Self.keyRGB(keyColourValue)
        updateOneWayLatch()
        let border = ave5.backColour.rgb
        // 0.6 is the scaling note from `keyThreshold`'s declaration: RGB distance
        // tops out at sqrt(3) ≈ 1.73 for two fully opposite colours, and a useful
        // key threshold lives in a small fraction of that — 0.6 gives the fader its
        // whole 0...1 travel across the range that is actually useful rather than
        // burying it in the bottom few percent.
        var params = BlendParams(
            mixAmount: Float(min(max(position, 0), 1)),
            opacity: Float(min(max(layerOpacity, 0), 1)),
            mode: Int32(blendMode.rawValue),
            keyR: Float(key.r),
            keyG: Float(key.g),
            keyB: Float(key.b),
            keyThreshold: Float(min(max(keyThreshold, 0), 1) * 0.6),
            keyEdge: Float(min(max(keyEdge, 0), 1) * 0.6),
            transition: Int32(transition.rawValue),
            ave5Keys: Int32(ave5.keys.rawValue),
            ave5Tiles: Int32(ave5.multi.tilesPerSide),
            ave5Edge: Int32(ave5.edge.rawValue),
            ave5Reversed: ave5DrawsReversed ? 1 : 0,
            // The joystick only moves the Ⓟ patterns; everything else stays centred.
            ave5CentreX: Float(ave5.isPositionable ? ave5.positionX : 0.5),
            ave5CentreY: Float(ave5.isPositionable ? ave5.positionY : 0.5),
            ave5BorderR: Float(border.r),
            ave5BorderG: Float(border.g),
            ave5BorderB: Float(border.b)
        )
        encoder.setFragmentBytes(&params, length: MemoryLayout<BlendParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()

        return target
    }

    /// Pulls this node's settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: positionCode) {
            position = value
        }
        if let value = registry.value(slot: identifier, code: .blendMode) {
            blendMode = BlendMode.from(normalised: value)
        }
        if let value = registry.value(slot: identifier, code: .transition) {
            transition = Transition.from(normalised: value)
        }
        // The ISF transition's own controls are registered under its identifier.
        isfTransition?.applyParameters(from: registry)
        ave5 = AVE5Wipe { registry.value(slot: identifier, code: $0) }
        if let value = registry.value(slot: identifier, code: .layerOpacity) {
            layerOpacity = value
        }
        if let value = registry.value(slot: identifier, code: .keyColour) {
            keyColourValue = value
        }
        if let value = registry.value(slot: identifier, code: .keyThreshold) {
            keyThreshold = value
        }
        if let value = registry.value(slot: identifier, code: .keyEdge) {
            keyEdge = value
        }
    }
}
