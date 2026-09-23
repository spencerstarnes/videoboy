//
//  ISFNode.swift — an ISF file as a node on the render graph (SPEC 2, SPEC 8).
//
//  Purpose : The one bridge between ISF and the rest of Videoboy. An `ISFNode` is an
//            ordinary `Node`: it takes the upstream picture, runs the file's passes,
//            and returns a picture. It is NOT a second plugin system — the file is
//            configuration for this one node type.
//  Inputs  : upstream textures (image inputs, in the file's order: an effect's
//            `inputImage` is `inputs[0]`); parameter values from the registry or set
//            directly; frame timing from `RenderContext`.
//  Outputs : one texture.
//  Connects: ISFProgram / ISFCompiler (what it draws), ParamRegistry (declared codes),
//            MetalContext (queue, render targets, the shared wet/dry blend).
//  Extend  : new auto-uniforms go in `ISFUniformLayout.builtIns`, get an offset in
//            `BuiltInOffsets`, and are written in `writeUniforms`. A new input type
//            needs a member type in the generator and a case in `writeUniforms`.
//
//  THE RULES EVERY EFFECT NODE HERE KEEPS (CLAUDE.md, "Smooth playback"):
//    - No compiling on the tick. Until a program is installed the node passes its
//      input straight through and `state` says `.compiling`; a failed file does the
//      same with `.failed(reason)`.
//    - Bypassed (wet/dry at 0) costs nothing and leaves persistent buffers alone, so
//      switching back on resumes a trail rather than restarting it.
//    - With `IDENTITY_AT_DEFAULTS` and every input at its default, no pass runs.
//    - No per-frame allocation on the render path: everything that can be worked out
//      from the file — which inputs exist, where each uniform lives, which texture
//      goes in which slot, the pass labels, the parsed size expressions — is worked
//      out ONCE in `install`, and `render` only reads it.
//    - Passes submit and do not wait. One queue orders the GPU work; the engine fences
//      once per frame, and a CPU reader waits on its own buffer.
//
//  PARAMETER CODES (SPEC 13). An input whose file declares `VIDEOBOY_CODE` with a
//  code that exists in `ParamCode` is exposed in `parameters`, so the registry, MIDI
//  learn and templates reach it with no extra code. Inputs without one are set by name
//  through `setValue(_:forInput:)` until ParamCode opens to runtime codes (ISF-PLAN M2).
//

import Foundation
import Metal

/// Where an ISF node is in its life.
public enum ISFNodeState: Equatable, Sendable {
    /// No program yet; the node passes its input through.
    case compiling
    /// Drawing.
    case ready
    /// The file could not be used. The string is one line, fit for a card.
    case failed(String)
}

/// An ISF file running as a graph node.
public final class ISFNode: Node {

    public let identifier: String
    public var latencyInFrames: Int { 0 }

    /// Effect, source or mix, by what the loaded file declares. `.effect` until known.
    public var kind: NodeKind {
        switch documentKind {
        case .generator: .source
        case .transition: .mix
        case .effect, .none: .effect
        }
    }

    public private(set) var state: ISFNodeState = .compiling
    public private(set) var program: ISFProgram?

    /// 0 bypasses the node entirely; 1 is fully applied. Driven by 02A.
    public var wetDry = 1.0

    private let context: MetalContext?

    // MARK: Worked out once per program, in `install`

    private var documentKind: ISFKind?
    /// The value inputs, in file order. `values[i]` belongs to `valueInputs[i]`.
    private var valueInputs: [ISFInput] = []
    private var inputIndexByName: [String: Int] = [:]
    /// Byte offset of each value input in the uniform block, parallel to `valueInputs`.
    private var inputOffsets: [Int] = []
    private var builtInOffsets = BuiltInOffsets()
    /// What goes in each `[[texture(i)]]` slot.
    private var textureBindings: [TextureSource] = []
    private var passLabels: [String] = []
    /// Parsed WIDTH/HEIGHT per pass.
    private var passSizes: [(width: ISFSizeExpression?, height: ISFSizeExpression?)] = []
    /// Uniform scratch, sized once per program and rewritten in place each pass.
    private var uniformBytes: [UInt8] = []

    /// Where the built-in uniforms sit in the block. -1 means absent (never, today).
    private struct BuiltInOffsets {
        var time = -1, timeDelta = -1, frameIndex = -1, passIndex = -1
        var renderSize = -1, date = -1, beat = -1, phase = -1
    }

    private enum TextureSource {
        /// The n-th image input: `inputs[n]` from the graph.
        case image(Int)
        /// A pass buffer, by target name.
        case buffer(String)
    }

    // MARK: Changing state

    /// Current value per value input, parallel to `valueInputs`.
    private var values: [[Double]] = []

    /// A pass target: the buffer last written (`front`, what readers see) and the one
    /// the next pass writes (`back`). Two textures, because reading and writing one
    /// texture in the same pass is undefined.
    private struct BufferPair {
        var front: MTLTexture
        var back: MTLTexture
        mutating func swap() { (front, back) = (back, front) }
    }
    private var buffers: [String: BufferPair] = [:]
    private var outputTarget: MTLTexture?
    private var blendTarget: MTLTexture?
    private var blackTexture: MTLTexture?

    private var framesRendered = 0
    private var firstPresentationTime: Double?
    private var previousPresentationTime: Double?
    private var cachedDate = SIMD4<Float>(0, 0, 0, 0)
    // This frame's timing, written by `advanceClock`, read by `writeUniforms`.
    private var presentationTimeSinceStart: Double = 0
    private var previousDelta: Double = 1.0 / 29.97
    private var musicalBeat: Double = 0
    private var musicalPhase: Double = 0

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    // MARK: - Loading

    /// Starts compiling `source` off the render path; the node passes through until
    /// the program arrives on the main thread.
    public func load(source: String, name: String, compiler: ISFCompiler = .shared) {
        guard let metal = context else {
            markFailed("no Metal device")
            return
        }
        state = .compiling
        compiler.compile(source: source, name: name, device: metal.device) { [weak self] result in
            switch result {
            case .success(let program): self?.install(program)
            case .failure(let error): self?.markFailed(error.description)
            }
        }
    }

    /// Makes `program` the one this node draws. Call on the main thread, between
    /// ticks. Buffers from a previous program are dropped; values for inputs that
    /// still exist by name are kept, so a hot reload does not reset the controls.
    public func install(_ program: ISFProgram) {
        let document = program.document
        let layout = program.shader.uniformLayout

        var previous: [String: [Double]] = [:]
        for (index, input) in valueInputs.enumerated() where index < values.count {
            previous[input.name] = values[index]
        }

        documentKind = document.kind
        valueInputs = document.valueInputs
        inputIndexByName = [:]
        values = []
        inputOffsets = []
        for (index, input) in valueInputs.enumerated() {
            inputIndexByName[input.name] = index
            if let kept = previous[input.name], kept.count == input.componentCount {
                values.append(kept)
            } else {
                values.append(input.defaultValue)
            }
            inputOffsets.append(layout.field(named: input.name)?.offset ?? -1)
            if let code = input.videoboyCode, ParamCode(rawValue: code) == nil {
                Log.warn(.isf, "'\(document.name)' input '\(input.name)' declares "
                    + "unknown code \(code); it is settable by name only")
            }
        }

        builtInOffsets = BuiltInOffsets(
            time: layout.field(named: "TIME")?.offset ?? -1,
            timeDelta: layout.field(named: "TIMEDELTA")?.offset ?? -1,
            frameIndex: layout.field(named: "FRAMEINDEX")?.offset ?? -1,
            passIndex: layout.field(named: "PASSINDEX")?.offset ?? -1,
            renderSize: layout.field(named: "RENDERSIZE")?.offset ?? -1,
            date: layout.field(named: "DATE")?.offset ?? -1,
            beat: layout.field(named: "VB_BEAT")?.offset ?? -1,
            phase: layout.field(named: "VB_PHASE")?.offset ?? -1)

        let imageNames = document.imageInputs.map(\.name)
        textureBindings = program.shader.textureNames.map { name in
            if let index = imageNames.firstIndex(of: name) { return .image(index) }
            return .buffer(name)
        }
        passLabels = document.passes.indices.map { "\(identifier) pass \($0)" }
        passSizes = document.passes.map { pass in
            (pass.widthExpression.flatMap(ISFNode.parseSize),
             pass.heightExpression.flatMap(ISFNode.parseSize))
        }
        uniformBytes = Array(repeating: 0, count: layout.size)

        buffers = [:]
        outputTarget = nil
        framesRendered = 0
        firstPresentationTime = nil
        previousPresentationTime = nil
        self.program = program
        state = .ready
    }

    /// Records a failure. The node keeps passing its input through.
    public func markFailed(_ reason: String) {
        program = nil
        documentKind = nil
        state = .failed(reason)
    }

    /// Clears persistent buffers (trails), as a cut does for the native echo.
    public func reset() {
        buffers = [:]
    }

    private static func parseSize(_ text: String) -> ISFSizeExpression? {
        let parsed = ISFSizeExpression.parse(text)
        if parsed == nil {
            Log.warn(.isf, "pass size '\(text)' is not an expression this host reads; using full size")
        }
        return parsed
    }

    // MARK: - Parameters

    /// 02A wet/dry, plus every scalar input whose file declares a known code.
    public var parameters: [Parameter] {
        var result = [Parameter(code: .wetDry, range: 0...1, defaultValue: 1)]
        for input in valueInputs where input.componentCount == 1 {
            guard let raw = input.videoboyCode, let code = ParamCode(rawValue: raw) else { continue }
            result.append(Parameter(
                code: code, range: ISFNode.range(of: input), defaultValue: input.defaultValue[0]))
        }
        return result
    }

    /// Pulls every declared code from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        for input in valueInputs where input.componentCount == 1 {
            guard let raw = input.videoboyCode, let code = ParamCode(rawValue: raw),
                  let value = registry.value(slot: identifier, code: code) else { continue }
            setValue(value, forInput: input.name)
        }
    }

    /// Sets a scalar input by name, clamped to the file's MIN/MAX.
    public func setValue(_ value: Double, forInput name: String) {
        setValue([value], forInput: name)
    }

    /// Sets any input by name. Wrong component counts and unknown names are logged
    /// and ignored rather than trusted.
    public func setValue(_ components: [Double], forInput name: String) {
        guard let index = inputIndexByName[name] else {
            Log.warn(.isf, "\(identifier): no input named '\(name)'")
            return
        }
        let input = valueInputs[index]
        guard components.count == input.componentCount else {
            Log.warn(.isf, "\(identifier): '\(name)' takes \(input.componentCount) values, got \(components.count)")
            return
        }
        values[index] = components.enumerated().map { component, value in
            guard value.isFinite else { return input.defaultValue[component] }
            var clamped = value
            if let minimum = input.minimum?[component] { clamped = max(clamped, minimum) }
            if let maximum = input.maximum?[component] { clamped = min(clamped, maximum) }
            return clamped
        }
    }

    /// The current value of an input, by name.
    public func value(ofInput name: String) -> [Double]? {
        inputIndexByName[name].map { values[$0] }
    }

    /// Whether every input sits at its DEFAULT.
    public var isAtDefaults: Bool {
        for index in valueInputs.indices {
            let defaults = valueInputs[index].defaultValue
            let current = values[index]
            for component in current.indices where abs(current[component] - defaults[component]) >= 1e-9 {
                return false
            }
        }
        return true
    }

    /// The registry range for a scalar input.
    static func range(of input: ISFInput) -> ClosedRange<Double> {
        switch input.type {
        case .bool, .event:
            return 0...1
        case .long:
            let low = Double(input.values.min() ?? 0)
            let high = Double(input.values.max() ?? 0)
            return low...max(low, high)
        default:
            let low = input.minimum?.first ?? 0
            let high = input.maximum?.first ?? 1
            return low...max(low, high)
        }
    }

    // MARK: - Rendering

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let program, state == .ready else { return inputs.first }
        let document = program.document
        let isEffect = documentKind == .effect

        let width: Int
        let height: Int
        if isEffect {
            guard let input = inputs.first else { return nil }
            guard wetDry > 0.001 else { return input }
            if document.identityAtDefaults, isAtDefaults { return input }
            width = input.width
            height = input.height
        } else {
            width = renderContext.width
            height = renderContext.height
        }

        advanceClock(renderContext)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            Log.error(.isf, "\(identifier) could not make a command buffer")
            return inputs.first
        }
        commandBuffer.label = identifier

        var result: MTLTexture?
        let passCount = document.passes.count
        for passIndex in 0..<passCount {
            let pass = document.passes[passIndex]
            let size = passSize(passIndex, width: width, height: height)
            let isLast = passIndex == passCount - 1
            let format = pass.float ? ISFProgram.floatPixelFormat : MetalContext.pixelFormat

            let target: MTLTexture
            if let name = pass.target {
                guard let pair = bufferPair(name, width: size.width, height: size.height,
                                            format: format, metal: metal, commandBuffer: commandBuffer) else {
                    return inputs.first
                }
                target = pair.back
            } else {
                if outputTarget == nil || outputTarget?.width != size.width || outputTarget?.height != size.height {
                    outputTarget = metal.makeRenderTarget(
                        width: size.width, height: size.height, label: "\(identifier)-out")
                }
                guard let outputTarget else { return inputs.first }
                target = outputTarget
            }
            guard let pipeline = program.pipeline(for: target.pixelFormat) else {
                Log.error(.isf, "\(identifier) has no pipeline for \(target.pixelFormat.rawValue)")
                return inputs.first
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                Log.error(.isf, "\(identifier) could not encode pass \(passIndex)")
                return inputs.first
            }
            encoder.label = passLabels[passIndex]
            encoder.setRenderPipelineState(pipeline)

            writeUniforms(passIndex: passIndex, width: size.width, height: size.height)
            uniformBytes.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }

            for binding in textureBindings.indices {
                let texture: MTLTexture?
                switch textureBindings[binding] {
                case .image(let index):
                    texture = index < inputs.count ? inputs[index] : nil
                case .buffer(let name):
                    // Readers see what was last written, which for the pass writing
                    // this buffer is the previous frame (persistent trails).
                    texture = buffers[name]?.front
                }
                encoder.setFragmentTexture(texture ?? black(metal), index: binding)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            if let name = pass.target {
                buffers[name]?.swap()
                if isLast { result = buffers[name]?.front }
            } else if isLast {
                result = outputTarget
            }
        }

        commandBuffer.addCompletedHandler { [identifier] buffer in
            if let error = buffer.error {
                Log.error(.isf, "\(identifier) GPU pass failed: \(error)")
            }
        }
        commandBuffer.commit()
        framesRendered += 1

        guard let wet = result else { return inputs.first }
        guard isEffect, wetDry < 0.999, let dry = inputs.first else { return wet }
        if blendTarget == nil || blendTarget?.width != dry.width || blendTarget?.height != dry.height {
            blendTarget = metal.makeRenderTarget(width: dry.width, height: dry.height, label: "\(identifier)-wetdry")
        }
        guard let blendTarget,
              metal.blend(dry: dry, wet: wet, amount: wetDry, into: blendTarget, label: identifier) else {
            return wet
        }
        return blendTarget
    }

    // MARK: - Render helpers

    /// Frame timing, advanced once per render. The graph is frame-clocked, so these
    /// advance per content frame, never per display refresh.
    private func advanceClock(_ renderContext: RenderContext) {
        if firstPresentationTime == nil { firstPresentationTime = renderContext.presentationTime }
        let start = firstPresentationTime ?? renderContext.presentationTime
        presentationTimeSinceStart = renderContext.presentationTime - start
        if let previous = previousPresentationTime {
            let delta = renderContext.presentationTime - previous
            if delta > 0 { previousDelta = delta }
        }
        previousPresentationTime = renderContext.presentationTime
        musicalBeat = renderContext.musicalPosition?.totalBeats ?? 0
        musicalPhase = renderContext.musicalPosition?.phase ?? 0
        // DATE changes once a second; reading the calendar every frame would allocate.
        if framesRendered % 30 == 0 { cachedDate = ISFNode.currentDate() }
    }

    private static func currentDate() -> SIMD4<Float> {
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let hours: Int = parts.hour ?? 0
        let minutes: Int = parts.minute ?? 0
        let secondsPart: Int = parts.second ?? 0
        let seconds: Int = hours * 3600 + minutes * 60 + secondsPart
        let year = Float(parts.year ?? 0)
        let month = Float(parts.month ?? 0)
        let day = Float(parts.day ?? 0)
        return SIMD4<Float>(year, month, day, Float(seconds))
    }

    private func passSize(_ index: Int, width: Int, height: Int) -> (width: Int, height: Int) {
        guard index < passSizes.count else { return (width, height) }
        let expressions = passSizes[index]
        // The common case — no size expression — returns before any lookup is built.
        guard expressions.width != nil || expressions.height != nil else { return (width, height) }

        let lookup: (String) -> Double? = { [self] name in
            switch name {
            case "WIDTH": return Double(width)
            case "HEIGHT": return Double(height)
            default: return value(ofInput: name)?.first
            }
        }
        let w = expressions.width.map { $0.evaluate(lookup) } ?? Double(width)
        let h = expressions.height.map { $0.evaluate(lookup) } ?? Double(height)
        // Clamped to something Metal will allocate. 8192 is far beyond SD and is only
        // here so a runaway expression cannot ask for a gigabyte texture.
        func legal(_ value: Double) -> Int {
            guard value.isFinite else { return 1 }
            return min(max(Int(value.rounded()), 1), 8192)
        }
        return (legal(w), legal(h))
    }

    /// The pair for a pass target, (re)built when size or format changes. New
    /// textures are cleared to transparent black on this frame's command buffer, so a
    /// persistent buffer's first read is defined.
    private func bufferPair(
        _ name: String, width: Int, height: Int, format: MTLPixelFormat,
        metal: MetalContext, commandBuffer: MTLCommandBuffer
    ) -> BufferPair? {
        if let existing = buffers[name], existing.front.width == width,
           existing.front.height == height, existing.front.pixelFormat == format {
            return existing
        }
        guard let first = makeTarget(width: width, height: height, format: format,
                                     label: "\(identifier)-\(name)-0", metal: metal),
              let second = makeTarget(width: width, height: height, format: format,
                                      label: "\(identifier)-\(name)-1", metal: metal) else {
            Log.error(.isf, "\(identifier) could not allocate buffer '\(name)' at \(width)x\(height)")
            return nil
        }
        for texture in [first, second] {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
        let pair = BufferPair(front: first, back: second)
        buffers[name] = pair
        return pair
    }

    private func makeTarget(width: Int, height: Int, format: MTLPixelFormat, label: String,
                            metal: MetalContext) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = metal.device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    /// A 1×1 black picture for any image the host has nothing to bind to yet.
    private func black(_ metal: MetalContext) -> MTLTexture? {
        if blackTexture == nil {
            blackTexture = metal.makeTexture(
                from: ImageBuffer(width: 1, height: 1, r: 0, g: 0, b: 0, a: 0), label: "isf-black")
        }
        return blackTexture
    }

    // MARK: - Uniforms

    /// Writes this pass's uniform block in place, by precomputed offset.
    private func writeUniforms(passIndex: Int, width: Int, height: Int) {
        let offsets = builtInOffsets
        store(Float(presentationTimeSinceStart), at: offsets.time)
        store(Float(previousDelta), at: offsets.timeDelta)
        store(Int32(framesRendered), at: offsets.frameIndex)
        store(Int32(passIndex), at: offsets.passIndex)
        store(SIMD2<Float>(Float(width), Float(height)), at: offsets.renderSize)
        store(cachedDate, at: offsets.date)
        store(Float(musicalBeat), at: offsets.beat)
        store(Float(musicalPhase), at: offsets.phase)

        for index in valueInputs.indices {
            let offset = inputOffsets[index]
            let current = values[index]
            switch valueInputs[index].type {
            case .float:
                store(Float(current[0]), at: offset)
            case .bool, .event:
                store(Int32(current[0] > 0.5 ? 1 : 0), at: offset)
            case .long:
                store(Int32(current[0].rounded()), at: offset)
            case .point2D:
                store(SIMD2<Float>(Float(current[0]), Float(current[1])), at: offset)
            case .color:
                store(SIMD4<Float>(Float(current[0]), Float(current[1]), Float(current[2]), Float(current[3])),
                      at: offset)
            case .image, .audio, .audioFFT:
                break
            }
        }
    }

    private func store<T>(_ value: T, at offset: Int) {
        guard offset >= 0 else { return }
        uniformBytes.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: value, toByteOffset: offset, as: T.self)
        }
    }
}
