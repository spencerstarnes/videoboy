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
//  Connects: H264LiveEncoder → MoshEngine → H264MoshDecoder; the FX panel's
//            "Datamosh · H.264" card (codes 35B–38B, plus 02A wet/dry).
//  Extend  : a new gesture is a field on `MoshControls` and a branch in MoshEngine;
//            this node only needs a parameter for it.
//
//  THE FRAME PATH (CLAUDE.md: the picture must never stutter):
//    - Neutral (mosh and bloom at 0, or wet/dry 0) returns the input at once and
//      holds no encoder. An idle card costs nothing.
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
public final class DatamoshNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect

    /// About one frame behind while active (encode + decode off the tick); none idle.
    public var latencyInFrames: Int { isRunning ? 1 : 0 }

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .moshAmount, range: 0...1, defaultValue: 0),
            Parameter(code: .moshBloom, range: 0...1, defaultValue: 0),
            Parameter(code: .moshHeal, range: 0...1, defaultValue: 0),
            Parameter(code: .moshBlocks, range: 0...1, defaultValue: 0.5)
        ]
    }

    // MARK: Controls (main thread)

    /// 0 bypasses entirely; the card's switch and wet/dry both drive this.
    public var wetDry = 1.0
    public var mosh = 0.0
    public var bloom = 0.0
    /// Rising through 0.5 lets one clean keyframe through.
    public var heal = 0.0
    /// Encoder bitrate, 0 starved … 1 clean.
    public var blocks = 0.5

    /// Whether an encoder is running. Read by the debug overlay and the self-QA.
    public private(set) var isRunning = false
    /// What the engine has done so far this run, for evidence and the overlay.
    public var statistics: MoshStatistics { shared.withLock { $0.statistics } }

    private let context: MetalContext?
    private var encoder: H264LiveEncoder?
    /// The size the current run was started for (its encoder may not exist yet).
    private var startingSize = (width: 0, height: 0)
    private var appliedBlocks = -1.0
    private var previousHeal = 0.0

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
        let active = wetDry > 0.001 && (mosh > 0.001 || bloom > 0.001)
        guard active, let metal = context else {
            if isRunning { stop() }
            return input
        }

        if !isRunning || startingSize.width != input.width || startingSize.height != input.height {
            start(width: input.width, height: input.height, metal: metal)
        }
        // Still being created off the tick: show the input meanwhile.
        guard let encoder else { return input }

        if blocks != appliedBlocks {
            encoder.setQuality(blocks)
            appliedBlocks = blocks
        }

        // Heal is an edge, not a level: crossing halfway asks for one keyframe.
        let healNow = heal >= 0.5 && previousHeal < 0.5
        previousHeal = heal
        let controls = MoshControls(
            mosh: mosh, bloomLength: MoshControls.bloomLength(fromNormalised: bloom))
        shared.withLock {
            $0.controls = controls
            if healNow { $0.healArmed = true }
        }

        submitForEncoding(input, encoder: encoder, forceKeyframe: healNow, metal: metal)
        return output(dry: input, metal: metal)
    }

    /// Blits the input to a staging texture; the completion handler hands the bytes
    /// to the encoder. Never waits.
    private func submitForEncoding(_ input: MTLTexture, encoder: H264LiveEncoder, forceKeyframe: Bool, metal: MetalContext) {
        guard encoder.framesInFlight < stagingCount else { return }
        guard let slot = claimStaging(), let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
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
    }

    /// The newest decoded picture, blended by wet/dry. Before the first picture
    /// arrives (the first frame or two after starting) the input is shown.
    private func output(dry: MTLTexture, metal: MetalContext) -> MTLTexture? {
        let (latest, generation) = shared.withLock { ($0.latest, $0.generation) }
        if let latest, generation != shownGeneration {
            if uploader == nil { uploader = TextureUploader(context: metal, label: "\(identifier)-mosh") }
            if let uploaded = uploader?.upload(latest) { lastOutput = uploaded }
            shownGeneration = generation
        }
        guard let wet = lastOutput, wet.width == dry.width, wet.height == dry.height else { return dry }
        guard wetDry < 0.999 else { return wet }

        if blendTarget?.width != dry.width || blendTarget?.height != dry.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.pixelFormat, width: dry.width, height: dry.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            blendTarget = metal.device.makeTexture(descriptor: descriptor)
        }
        guard let blendTarget,
              metal.blend(dry: dry, wet: wet, amount: wetDry, into: blendTarget, label: identifier) else { return wet }
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
    /// clean — letting go of the mosh IS the heal.
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
        if let value = registry.value(slot: identifier, code: .moshBloom) { bloom = value }
        if let value = registry.value(slot: identifier, code: .moshHeal) { heal = value }
        if let value = registry.value(slot: identifier, code: .moshBlocks) { blocks = value }
    }
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
