//
//  ScopeOverlayNode.swift — a scope, on air.
//
//  Purpose : Puts the scope into the picture that goes to programme, rather than only
//            into the preview. SEND turns an instrument into part of the video feed.
//  Inputs  : the finished programme picture, and a scope image set from outside.
//  Outputs : the same picture with the scope screened onto it.
//  Connects: Engine (which puts it last in the chain), ShellController (which hands it
//            the scope image), ScopeRenderer, ScopeSelection.
//  Extend  : anything else that needs to be laid over the finished picture from the
//            CPU side — a now-playing card, a countdown — is the same shape as this.
//            Take the rectangle and the image; do not teach this node what a scope is.
//
//  ── THE ONLY RULE THAT MATTERS HERE ─────────────────────────────────────────────
//
//  This node is LAST IN THE CHAIN, so it runs on every frame that goes to air, whether
//  or not anything is being sent. So when nothing is set it returns its input
//  untouched — no pass, no upload, no allocation. A node that costs a full-frame pass
//  to reproduce its input is exactly the sort of thing that eats the frame budget
//  while appearing to do nothing.
//
//  The image is uploaded only when it CHANGES. Scopes refresh well below frame rate —
//  a few times a second — so at 29.97 the overwhelming majority of frames reuse the
//  texture that is already there.
//

import Foundation
import Metal
import simd

/// Screens a CPU-drawn image over the picture, in a chosen rectangle.
public final class ScopeOverlayNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    public var latencyInFrames: Int { 0 }

    private let context: MetalContext?
    private var target: MTLTexture?
    private var overlayTexture: MTLTexture?

    /// Bumped whenever a new image arrives, so the render knows to re-upload.
    private var pendingImage: ImageBuffer?
    private let lock = NSLock()

    /// Where the overlay sits, in 0...1 of the frame, origin top left.
    public var placement: ScopePlacement = .full
    /// How far the picture behind the overlay is held back.
    public var dimming: Double = 0
    /// How strongly the trace is added.
    public var opacity: Double = 1

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public var parameters: [Parameter] { [] }
    public func applyParameters(from registry: ParamRegistry) {}

    /// Hands over the image to lay on, or nil to stop.
    ///
    /// Called from the UI thread at scope refresh rate. It takes a lock and stores a
    /// reference — no work, so it cannot hold the caller up.
    public func setOverlay(_ image: ImageBuffer?) {
        lock.lock()
        pendingImage = image
        if image == nil { overlayTexture = nil }
        lock.unlock()
    }

    /// Whether anything is currently being laid on.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingImage != nil || overlayTexture != nil
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }

        lock.lock()
        if let pending = pendingImage {
            // Uploading only on change is what keeps this off the per-frame budget.
            overlayTexture = metal.makeTexture(from: pending, label: identifier)
            pendingImage = nil
        }
        let overlay = overlayTexture
        lock.unlock()

        // Nothing to send: hand the picture straight back. No pass, no cost.
        guard let overlay else { return input }

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
            dim: Float(dimming))

        encoder.setRenderPipelineState(metal.scopeOverlayPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(overlay, index: 1)
        encoder.setFragmentBytes(
            &params, length: MemoryLayout<ScopeOverlayParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return target
    }
}

/// Must match `ScopeOverlayParams` in the shader source.
struct ScopeOverlayParams {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var opacity: Float
    var dim: Float
}
