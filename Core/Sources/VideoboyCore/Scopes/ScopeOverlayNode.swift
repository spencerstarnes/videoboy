//
//  ScopeOverlayNode.swift — DATA BURN: scopes and data lines, into a sub-mix.
//
//  Purpose : Puts the scope and the NAME/TC text into a sub-mix's picture, rather than
//            only onto its monitor, so they reach air whenever that sub-mix is mixed
//            into PROGRAM. One per sub-mix, after its data stage.
//  Inputs  : the finished sub-mix picture; a scope image set from outside at scope
//            refresh rate; data lines pulled once per render from `textProvider`.
//  Outputs : the same picture with the scope screened onto it and the text laid over.
//  Connects: Engine (which wires it between the bus data stage and the mix),
//            ShellController (scope image, text provider, style), ScopeRenderer,
//            DataBurnRenderer, ScopeSelection.
//  Extend  : another CPU-drawn layer is a third texture and rectangle in the same
//            pass. Take the rectangle and the image; do not teach this node what a
//            scope or a timecode is.
//
//  ── THE ONLY RULE THAT MATTERS HERE ─────────────────────────────────────────────
//
//  This node is on the path of every frame a sub-mix produces, burning or not. So
//  when nothing is set it returns its input untouched — no pass, no upload, no
//  allocation. A node that costs a full-frame pass to reproduce its input is exactly
//  the sort of thing that eats the frame budget while appearing to do nothing.
//
//  The scope is uploaded only when it CHANGES (a few times a second). The text is
//  redrawn only when its lines change — every frame while a timecode ticks — and that
//  redraw is a small block, not a frame, uploaded through a reused `TextureUploader`.
//
//  WHY THE TEXT IS PULLED, NOT PUSHED. The provider is called inside `render`, after
//  the sources upstream have advanced their playheads for this frame. Pushing lines
//  from the UI before the render would burn the PREVIOUS frame's timecode onto the
//  picture — a burn-in one frame out of step with its own picture.
//

import Foundation
import Metal
import simd

/// Burns a CPU-drawn scope and a block of text into the picture.
public final class ScopeOverlayNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    public var latencyInFrames: Int { 0 }

    private let context: MetalContext?
    private var target: MTLTexture?
    private var overlayTexture: MTLTexture?
    /// Reused for every scope image: a burned scope refreshes several times a second,
    /// and a fresh texture each time is an allocation on the tick.
    private var overlayUploader: TextureUploader?

    /// Bumped whenever a new image arrives, so the render knows to re-upload.
    private var pendingImage: ImageBuffer?
    private let lock = NSLock()

    /// Where the overlay sits, in 0...1 of the frame, origin top left.
    public var placement: ScopePlacement = .full
    /// How far the picture behind the overlay is held back.
    public var dimming: Double = 0
    /// How strongly the trace is added.
    public var opacity: Double = 1

    // MARK: Text

    /// Returns this frame's data lines, or none. Called once per render.
    public var textProvider: (() -> [String])?
    /// Which corner the text block sits in.
    public var textAnchor: DataBurnAnchor = .topLeft
    /// How the text looks. Changing it redraws on the next frame.
    public var textStyle = DataBurnStyle() {
        didSet { if textStyle != oldValue { drawnLines = nil } }
    }

    private var textUploader: TextureUploader?
    private var textTexture: MTLTexture?
    private var textRect: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0)
    /// What `textTexture` shows, and at which frame height, so an unchanged frame
    /// reuses it.
    private var drawnLines: [String]?
    private var drawnHeight = 0

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public var parameters: [Parameter] { [] }
    public func applyParameters(from registry: ParamRegistry) {}

    /// Hands over the scope image to lay on, or nil to stop.
    ///
    /// Called from the UI thread at scope refresh rate. It takes a lock and stores a
    /// reference — no work, so it cannot hold the caller up.
    public func setOverlay(_ image: ImageBuffer?) {
        lock.lock()
        pendingImage = image
        if image == nil { overlayTexture = nil }
        lock.unlock()
    }

    /// Whether a scope is currently being laid on. Text is `isBurningText`.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingImage != nil || overlayTexture != nil
    }

    /// Whether the last render burned any text.
    public var isBurningText: Bool { textTexture != nil }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }

        lock.lock()
        if let pending = pendingImage {
            // Uploading only on change is what keeps this off the per-frame budget.
            if overlayUploader == nil {
                overlayUploader = TextureUploader(context: metal, label: "\(identifier).scope")
            }
            overlayTexture = overlayUploader?.upload(pending)
            pendingImage = nil
        }
        let overlay = overlayTexture
        lock.unlock()

        updateText(frameWidth: input.width, frameHeight: input.height, metal: metal)
        let text = textTexture

        // Nothing to burn: hand the picture straight back. No pass, no cost.
        guard overlay != nil || text != nil else { return input }

        let width = input.width
        let height = input.height
        if target == nil || target?.width != width || target?.height != height {
            target = metal.makeRenderTarget(width: width, height: height, label: identifier)
        }
        guard let target else { return input }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its overlay pass")
            return input
        }

        let rect = placement.rect
        var params = ScopeOverlayParams(
            origin: SIMD2<Float>(Float(rect.x), Float(rect.y)),
            size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            opacity: Float(opacity),
            dim: Float(dimming),
            textOrigin: SIMD2<Float>(Float(textRect.x), Float(textRect.y)),
            textSize: SIMD2<Float>(Float(textRect.width), Float(textRect.height)),
            hasScope: overlay == nil ? 0 : 1,
            hasText: text == nil ? 0 : 1)

        encoder.setRenderPipelineState(metal.scopeOverlayPipeline)
        encoder.setFragmentTexture(input, index: 0)
        // An absent layer still needs SOMETHING bound; the flags stop it being read.
        encoder.setFragmentTexture(overlay ?? input, index: 1)
        encoder.setFragmentTexture(text ?? input, index: 2)
        encoder.setFragmentBytes(
            &params, length: MemoryLayout<ScopeOverlayParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        metal.submit(commandBuffer, label: identifier)

        return target
    }

    /// Redraws the text block if this frame's lines differ from the last ones drawn.
    private func updateText(frameWidth: Int, frameHeight: Int, metal: MetalContext) {
        let lines = textProvider?() ?? []
        guard !lines.isEmpty else {
            textTexture = nil
            drawnLines = nil
            return
        }
        guard lines != drawnLines || frameHeight != drawnHeight else { return }
        drawnLines = lines
        drawnHeight = frameHeight

        guard let image = DataBurnRenderer.render(
            lines: lines, style: textStyle, frameHeight: frameHeight) else {
            textTexture = nil
            return
        }
        if textUploader == nil {
            textUploader = TextureUploader(context: metal, label: "\(identifier).text")
        }
        textTexture = textUploader?.upload(image)
        textRect = DataBurnRenderer.rect(
            for: image, anchor: textAnchor, frameWidth: frameWidth, frameHeight: frameHeight)
    }
}

/// Must match `ScopeOverlayParams` in the shader source.
struct ScopeOverlayParams {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var opacity: Float
    var dim: Float
    var textOrigin: SIMD2<Float>
    var textSize: SIMD2<Float>
    var hasScope: Float
    var hasText: Float
}
