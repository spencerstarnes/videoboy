//
//  DatamoshNode.swift — live H.264 datamoshing as an effect in the chain.
//
//  Purpose : Real datamoshing, live, on whatever reaches this point in the graph: a
//            clip, a camera, a whole bus. The picture is encoded to H.264 on the
//            hardware encoder, the coded frames are rearranged (MoshEngine), and
//            libavcodec decodes the result. Nothing is simulated: the smear is the
//            codec's own motion compensation applied to the wrong picture.
//  Inputs  : one texture.
//  Outputs : the moshed picture, or the input untouched when neutral.
//  Connects: H264LiveEncoder → MoshEngine → H264MoshDecoder; MoshHeal (the eased
//            heal, heal on the beat); the "mosh layer" shader (heal shape, blend,
//            opacity); the FX panel's "Datamosh · H.264" card (codes 35B–3EB, 01A
//            opacity, plus 02A wet/dry — the card's switch).
//  Extend  : a new gesture is a field on `MoshControls` and a branch in MoshEngine;
//            this node only needs a parameter for it.
//
//  THE FRAME PATH (CLAUDE.md: the picture must never stutter):
//    - Neutral (mosh, melt and bloom at 0, or wet/dry 0) returns the input and
//      holds no encoder. An idle card costs nothing. Letting go eases the clean
//      picture back in over the heal time first, then releases the encoder.
//    - The layer pass (heal shape, blend mode, opacity) runs only while one of them
//      is doing something; a plain full-strength mosh returns the decoded picture.
//    - Active, the render thread only ENCODES A BLIT into one of three staging
//      textures and submits it. The copy into the encoder's buffer and the encode
//      call happen in that command buffer's completion handler, off the main
//      thread. Nothing here waits for the GPU.
//    - Rearranging and decoding run on this node's own serial queue. The render
//      thread shows the newest decoded picture, so output trails input by about one
//      frame — declared as `latencyInFrames` while active.
//    - Backpressure: if three frames are already in flight the new one is skipped
//      rather than queued, so a slow moment can never grow into a backlog.
//

import Foundation
import Metal

/// Live datamosh on one point of the graph.
public final class DatamoshNode: Node, ParameterApplying {

    public let identifier: String
    public let kind: NodeKind = .effect

    /// About one frame behind while active (encode + decode off the tick); none idle.
    public var latencyInFrames: Int { isRunning ? 1 : 0 }

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .moshAmount, range: 0...1, defaultValue: 0),
            Parameter(code: .moshMelt, range: 0...1, defaultValue: 0),
            Parameter(code: .moshBloom, range: 0...1, defaultValue: 0),
            Parameter(code: .moshLoop, range: 0...1, defaultValue: Self.defaultLoop),
            Parameter(code: .moshBlocks, range: 0...1, defaultValue: 0.5),
            Parameter(code: .moshHeal, range: 0...1, defaultValue: 0, isMomentary: true),
            Parameter(code: .moshHealEvery, range: 0...1, defaultValue: 0),
            Parameter(code: .moshHealTime, range: 0...1, defaultValue: Self.defaultHealTime),
            Parameter(code: .moshHealShape, range: 0...1, defaultValue: 0),
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .moshBlend, range: 0...1, defaultValue: 0),
            Parameter(code: .moshHold, range: 0...1, defaultValue: 0, isMomentary: true)
        ]
    }

    /// A four-frame loop: long enough to read as a gesture, short enough to stream.
    public static let defaultLoop = 0.2
    /// Half a second of easing back to clean: a graceful exit unless asked otherwise.
    public static let defaultHealTime = 0.25

    /// The blend modes the card offers, in `BlendMode` order. Key is left out: it
    /// needs a key colour this card has no controls for.
    public static let blendModes: [BlendMode] = BlendMode.allCases.filter { $0 != .key }

    /// A blend mode's name for the card's narrow readout (the full names are for the
    /// mixer's menu, where there is room).
    public static func blendShortName(_ mode: BlendMode) -> String {
        switch mode {
        case .normal: "norm"
        case .multiply: "mult"
        case .screen: "scrn"
        case .overlay: "ovly"
        case .lighten: "light"
        case .darken: "dark"
        case .difference: "diff"
        case .add: "add"
        case .subtract: "sub"
        case .colorDodge: "dodge"
        case .colorBurn: "burn"
        case .hardLight: "hard"
        case .softLight: "soft"
        case .key: "key"
        }
    }

    /// The blend fader (0...1) as a mode.
    public static func blendMode(fromNormalised value: Double) -> BlendMode {
        blendModes[NormalisedSweep.index(value, count: blendModes.count)]
    }

    /// Macroblock size for the blocks and wipe heal shapes, in output pixels (H.264's).
    static let healBlockSize: Float = 16

    // MARK: Controls (main thread)

    /// 0 bypasses entirely; the card's switch and wet/dry both drive this.
    public var wetDry = 1.0
    public var mosh = 0.0
    /// Random P-frame drops, 0 none … 1 about one in three.
    public var melt = 0.0
    /// Share of frames that are bloom replays, 0 off … 1 every frame.
    public var bloom = 0.0
    /// Bloom's loop length, 0 one frame … 1 sixteen.
    public var loop = DatamoshNode.defaultLoop
    /// Rising through 0.5 asks for a heal (the card's button, or a MIDI note).
    public var heal = 0.0
    /// A press latched by the registry since the last frame, however short it was.
    public var healPressed = false
    /// Heal on the beat, as a `MoshHealEvery` position.
    public var healEvery = 0.0
    /// How long a heal (and letting go) eases back to clean, 0 instant … 1 two seconds.
    public var healTime = DatamoshNode.defaultHealTime
    /// How the clean picture comes back, as a `MoshHealShape` position.
    public var healShape = 0.0
    /// How strongly the mosh lies over the clean picture.
    public var opacity = 1.0
    /// How the mosh combines with the clean picture, as a `blendModes` position.
    public var blend = 0.0
    /// Encoder bitrate, 0 starved … 1 clean.
    public var blocks = 0.5
    /// The MOSH key: at or above 0.5 while it is held (the card's key or a MIDI note).
    public var hold = 0.0
    /// A MOSH press latched by the registry since the last frame, so a tap shorter
    /// than a frame still moshes for one.
    public var holdPressed = false

    /// Whether the MOSH key is holding the node at full mosh this frame.
    public var isHeld: Bool { hold >= 0.5 || holdPressed }

    /// Whether an encoder is running. Read by the debug overlay and the self-QA.
    public private(set) var isRunning = false
    /// What the engine has done so far this run, for evidence and the overlay.
    public var statistics: MoshStatistics { shared.withLock { $0.statistics } }
    /// Heals asked for this run (button, MIDI or beat), for evidence.
    public private(set) var healCount = 0
    /// How much of the clean picture is showing through right now, 0...1.
    public var healProgress: Double { envelope.clean }

    private let context: MetalContext?
    private var encoder: H264LiveEncoder?
    /// The size the current run was started for (its encoder may not exist yet).
    private var startingSize = (width: 0, height: 0)
    private var appliedBlocks = -1.0
    private var previousHeal = 0.0
    private var envelope = MoshHealEnvelope()
    private var beatTrigger = MoshBeatTrigger()
    /// A keyframe was asked for and has not yet gone to the encoder (it was backed up).
    private var keyframeWanted = false

    /// Staging textures the GPU copies the input into, cycled so one can be read
    /// on a completion thread while the next frame's blit writes another.
    private var staging: [MTLTexture] = []
    private var stagingBusy: [Bool] = []
    private var nextStaging = 0
    private let stagingCount = 3

    private var uploader: TextureUploader?
    private var shownGeneration = 0
    private var lastOutput: MTLTexture?
    private var blendTarget: MTLTexture?

    // MARK: Pipeline (its own queue)

    private let pipeline: DispatchQueue
    private var engine = MoshEngine()
    private var decoder: H264MoshDecoder?
    /// Bumped on every start and stop, so a frame from a previous run that arrives
    /// late is recognised and dropped instead of being shown.
    private var runID = 0

    /// State crossing threads, behind one lock.
    private struct Shared {
        var controls = MoshControls()
        /// A heal was asked for and its keyframe has not come through yet.
        var healArmed = false
        /// A healed keyframe has been decoded into `latest`.
        var keyframeLanded = false
        var latest: ImageBuffer?
        var generation = 0
        var statistics = MoshStatistics()
        var runID = 0
    }
    private let shared = LockedValue(Shared())

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
        self.pipeline = DispatchQueue(label: "videoboy.mosh.\(identifier)", qos: .userInteractive)
    }

    deinit { encoder?.invalidate(completingPending: false) }

    // MARK: - Render

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let input = inputs.first else { return nil }
        // Taken on every frame, used or not: a press while the card is idle must not
        // fire later, the moment the mosh is pushed up.
        let pressed = healPressed || (heal >= 0.5 && previousHeal < 0.5)
        healPressed = false
        previousHeal = heal
        // MOSH held is full mosh, whatever the faders say: every frame a replay of
        // the captured loop, so the picture streams at once with no cut needed, and
        // keyframes and cuts dropped. Let go, the faders are back in charge — at zero
        // that is the same eased exit as pulling them down.
        let held = isHeld
        holdPressed = false
        let moshNow = held ? 1 : mosh
        let bloomNow = held ? 1 : bloom
        let engaged = moshNow > 0.001 || melt > 0.001 || bloomNow > 0.001
        // The switch (wet/dry) is a bypass: off is off, at once. Letting the faders
        // go is not — a running mosh eases out below before it is released.
        guard wetDry > 0.001, let metal = context, engaged || isRunning else {
            if isRunning { stop() }
            return input
        }

        if !isRunning || startingSize.width != input.width || startingSize.height != input.height {
            guard engaged else {
                stop()
                return input
            }
            start(width: input.width, height: input.height, metal: metal)
        }
        // Still being created off the tick: show the input meanwhile.
        guard let encoder else {
            if !engaged { stop() }
            return input
        }

        if blocks != appliedBlocks {
            encoder.setQuality(blocks)
            appliedBlocks = blocks
        }

        // HEAL. The button is an edge, not a level: crossing halfway is one press
        // (latched by the registry, so a tap between frames counts). The beat is
        // another way to press it.
        let healFrames = MoshHealEnvelope.frames(fromNormalised: healTime)
        let onBeat = beatTrigger.fires(
            every: MoshHealEvery.from(normalised: healEvery), at: renderContext.musicalPosition)
        if engaged && (pressed || onBeat) {
            healCount += 1
            if envelope.trigger(frames: healFrames) == .requestKeyframe { requestKeyframe() }
        }
        switch envelope.advance(frames: healFrames, neutral: !engaged) {
        case .stop:
            stop()
            return input
        case .requestKeyframe:
            requestKeyframe()
        case .none:
            break
        }

        let controls = MoshControls(
            mosh: moshNow, melt: melt, bloom: bloomNow,
            bloomLength: bloomNow > 0.001 ? MoshControls.bloomLength(fromNormalised: loop) : 0)
        shared.withLock { $0.controls = controls }

        if submitForEncoding(input, encoder: encoder, forceKeyframe: keyframeWanted, metal: metal) {
            keyframeWanted = false
        }
        return output(dry: input, metal: metal)
    }

    /// Asks for one clean keyframe: from the encoder on the next frame that is
    /// actually submitted, and through the engine when it arrives.
    private func requestKeyframe() {
        keyframeWanted = true
        shared.withLock { $0.healArmed = true }
    }

    /// Blits the input to a staging texture; the completion handler hands the bytes
    /// to the encoder. Never waits. False when the frame was skipped (backpressure),
    /// so a keyframe request riding on it is kept for the next one.
    @discardableResult
    private func submitForEncoding(_ input: MTLTexture, encoder: H264LiveEncoder, forceKeyframe: Bool, metal: MetalContext) -> Bool {
        guard encoder.framesInFlight < stagingCount else { return false }
        guard let slot = claimStaging() else { return false }
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            releaseStaging(slot)
            return false
        }
        let target = staging[slot]
        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        let width = input.width
        let height = input.height
        commandBuffer.addCompletedHandler { [weak self, weak encoder] _ in
            // Metal's completion thread: copy straight into the encoder's buffer.
            if let encoder {
                encoder.encode(forceKeyframe: forceKeyframe) { base, bytesPerRow in
                    target.getBytes(base, bytesPerRow: bytesPerRow,
                                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
            }
            DispatchQueue.main.async { self?.releaseStaging(slot) }
        }
        metal.submit(commandBuffer, label: "\(identifier) mosh staging")
        return true
    }

    /// The newest decoded picture, laid over the clean input: healed by the envelope's
    /// shape, combined by the blend mode, at opacity × wet/dry. Before the first
    /// picture arrives (the first frame or two after starting) the input is shown.
    private func output(dry: MTLTexture, metal: MetalContext) -> MTLTexture? {
        let (latest, generation, landed) = shared.withLock { value -> (ImageBuffer?, Int, Bool) in
            let landed = value.keyframeLanded
            value.keyframeLanded = false
            return (value.latest, value.generation, landed)
        }
        if let latest, generation != shownGeneration {
            if uploader == nil { uploader = TextureUploader(context: metal, label: "\(identifier)-mosh") }
            if let uploaded = uploader?.upload(latest) { lastOutput = uploaded }
            shownGeneration = generation
        }
        if landed { envelope.keyframeShown() }
        guard let wet = lastOutput, wet.width == dry.width, wet.height == dry.height else { return dry }

        let mode = Self.blendMode(fromNormalised: blend)
        let strength = min(max(opacity, 0), 1) * min(max(wetDry, 0), 1)
        let clean = envelope.clean
        // The common case costs no pass at all.
        if clean <= 0 && mode == .normal && strength >= 0.999 { return wet }
        if clean >= 1 && mode == .normal { return dry }

        if blendTarget?.width != dry.width || blendTarget?.height != dry.height {
            blendTarget = metal.makeRenderTarget(width: dry.width, height: dry.height, label: "\(identifier)-mosh-layer")
        }
        guard let blendTarget else { return wet }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = blendTarget
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.mosh, "\(identifier) could not encode its layer pass")
            return wet
        }
        encoder.label = "\(identifier)-mosh-layer"
        encoder.setRenderPipelineState(metal.moshLayerPipeline)
        encoder.setFragmentTexture(dry, index: 0)
        encoder.setFragmentTexture(wet, index: 1)
        var params = MoshLayerParams(
            opacity: Float(strength),
            mode: Int32(mode.rawValue),
            heal: Float(clean),
            shape: Int32(MoshHealShape.from(normalised: healShape).rawValue),
            blockSize: Self.healBlockSize,
            // A new block pattern for every heal, so two in a row do not look alike.
            seed: Float(healCount % 1000))
        encoder.setFragmentBytes(&params, length: MemoryLayout<MoshLayerParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        metal.submit(commandBuffer, label: "\(identifier) mosh layer")
        return blendTarget
    }

    // MARK: - Start / stop

    /// Starts a run. The encoder and decoder are created on the pipeline queue —
    /// making a VideoToolbox session takes tens of milliseconds, which on the render
    /// thread would be a dropped frame at exactly the moment the fader is touched.
    /// Until the encoder arrives the node passes its input through.
    private func start(width: Int, height: Int, metal: MetalContext) {
        stop()
        runID += 1
        let run = runID
        shared.withLock {
            $0 = Shared()
            $0.runID = run
        }
        prepareStaging(width: width, height: height, metal: metal)
        appliedBlocks = -1
        envelope.reset()
        keyframeWanted = false
        healCount = 0
        isRunning = true
        startingSize = (width, height)

        let identifier = identifier
        pipeline.async { [weak self] in
            guard let self else { return }
            self.engine.reset()
            do {
                self.decoder = try H264MoshDecoder()
                let created = try H264LiveEncoder(width: width, height: height) { [weak self] unit in
                    self?.pipeline.async { self?.consume(unit, run: run) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.runID == run else {
                        created.invalidate(completingPending: false)
                        return
                    }
                    self.encoder = created
                    Log.info(.mosh, "\(identifier) moshing at \(width)x\(height)")
                }
            } catch {
                // Visible, not fatal: the card stays, the picture passes through clean.
                Log.error(.mosh, "\(identifier) cannot mosh: \(error)")
                self.decoder = nil
            }
        }
    }

    /// Releases the encoder and clears the picture. The next frame shows the input
    /// clean. Reached at once from the switch, or after the release fade when the
    /// faders are let go (MoshHealEnvelope).
    private func stop() {
        guard isRunning || encoder != nil else { return }
        encoder?.invalidate(completingPending: false)
        encoder = nil
        isRunning = false
        startingSize = (0, 0)
        runID += 1
        let run = runID
        shared.withLock {
            $0.latest = nil
            $0.runID = run
        }
        lastOutput = nil
        envelope.reset()
        keyframeWanted = false
        pipeline.async { [weak self] in
            self?.decoder = nil
            self?.engine.reset()
        }
        Log.info(.mosh, "\(identifier) released")
    }

    /// Pipeline queue: one encoded picture through the engine and the decoder.
    private func consume(_ unit: H264AccessUnit, run: Int) {
        let (controls, healArmed, current) = shared.withLock { ($0.controls, $0.healArmed, $0.runID) }
        guard run == current, let decoder else { return }

        var controlsNow = controls
        controlsNow.heal = healArmed
        var picture: ImageBuffer?
        var healed = false
        for fed in engine.process(unit, controls: controlsNow) {
            if fed.isKeyframe { healed = true }
            if let decoded = decoder.decode(fed) { picture = decoded }
        }
        let statistics = engine.statistics
        shared.withLock {
            guard $0.runID == run else { return }
            if healed { $0.healArmed = false }
            if let picture {
                $0.latest = picture
                $0.generation &+= 1
                if healed { $0.keyframeLanded = true }
            }
            $0.statistics = statistics
        }
    }

    // MARK: - Staging

    private func prepareStaging(width: Int, height: Int, metal: MetalContext) {
        if staging.first?.width == width, staging.first?.height == height { return }
        staging = []
        stagingBusy = []
        for index in 0..<stagingCount {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let texture = metal.device.makeTexture(descriptor: descriptor) else {
                Log.error(.mosh, "\(identifier) could not allocate staging texture \(index)")
                continue
            }
            texture.label = "\(identifier)-mosh-staging-\(index)"
            staging.append(texture)
            stagingBusy.append(false)
        }
    }

    private func claimStaging() -> Int? {
        for offset in 0..<staging.count {
            let slot = (nextStaging + offset) % staging.count
            if !stagingBusy[slot] {
                stagingBusy[slot] = true
                nextStaging = (slot + 1) % staging.count
                return slot
            }
        }
        return nil
    }

    private func releaseStaging(_ slot: Int) {
        if stagingBusy.indices.contains(slot) { stagingBusy[slot] = false }
    }

    // MARK: - Parameters

    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        if let value = registry.value(slot: identifier, code: .moshAmount) { mosh = value }
        if let value = registry.value(slot: identifier, code: .moshMelt) { melt = value }
        if let value = registry.value(slot: identifier, code: .moshBloom) { bloom = value }
        if let value = registry.value(slot: identifier, code: .moshLoop) { loop = value }
        if let value = registry.value(slot: identifier, code: .moshHeal) { heal = value }
        if registry.consumePress(slot: identifier, code: .moshHeal) { healPressed = true }
        if let value = registry.value(slot: identifier, code: .moshHealEvery) { healEvery = value }
        if let value = registry.value(slot: identifier, code: .moshHealTime) { healTime = value }
        if let value = registry.value(slot: identifier, code: .moshHealShape) { healShape = value }
        if let value = registry.value(slot: identifier, code: .opacity) { opacity = value }
        if let value = registry.value(slot: identifier, code: .moshBlend) { blend = value }
        if let value = registry.value(slot: identifier, code: .moshBlocks) { blocks = value }
        if let value = registry.value(slot: identifier, code: .moshHold) { hold = value }
        if registry.consumePress(slot: identifier, code: .moshHold) { holdPressed = true }
    }
}

/// The mosh layer shader's parameters. Layout matches `MoshLayerParams` in the Metal
/// source: six 4-byte fields.
private struct MoshLayerParams {
    var opacity: Float
    var mode: Int32
    var heal: Float
    var shape: Int32
    var blockSize: Float
    var seed: Float
}

/// A value behind a lock, for the few pieces of state that cross threads.
final class LockedValue<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
