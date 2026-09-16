//
//  MetalPreviewView.swift — a Metal-backed 4:3 video preview.
//
//  Purpose : Every preview in the window (A, B, C, D, ONE, TWO, PROGRAM) is one of
//            these. It draws whatever texture it is given, letterboxed into a 4:3
//            box, and shows a labelled empty state when there is nothing to draw —
//            never a blank or a crash (SPEC 1.5).
//  Inputs  : an `MTLTexture` set by the render loop, plus a caption.
//  Outputs : pixels on screen.
//  Connects: MetalContext (device, blit pipeline), RenderLoop (which calls `present`).
//  Extend  : this view only blits. Compositing happens in the graph before it gets
//            here, so previews and output always show the same thing.
//

import AppKit
import QuartzCore
import Metal
import VideoboyCore

/// Draws one texture, or an empty state.
final class MetalPreviewView: NSView {

    /// Text drawn over the picture (the mockup's IRE readout / channel letter).
    var caption: String {
        didSet { captionLabel.stringValue = caption }
    }

    /// The texture to draw. Setting it schedules a redraw.
    var texture: MTLTexture? {
        didSet { needsDisplay = true }
    }

    private let captionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "no source")
    private var metalLayer: CAMetalLayer?

    /// - Parameter caption: overlay text, e.g. "A" or "720x480 · 480i".
    init(caption: String) {
        self.caption = caption
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true

        if let context = MetalContext.shared {
            let metalLayer = CAMetalLayer()
            metalLayer.device = context.device
            metalLayer.pixelFormat = MetalContext.pixelFormat
            metalLayer.framebufferOnly = true
            // Standard-definition video is not HiDPI. Forcing scale 1 keeps the
            // pixel mapping exact and avoids resampling a 720x480 picture twice.
            metalLayer.contentsScale = 1.0
            layer?.addSublayer(metalLayer)
            self.metalLayer = metalLayer
        } else {
            Log.warn(.render, "preview '\(caption)' has no Metal device; showing empty state only")
        }

        emptyLabel.font = Theme.Font.tinyLabel
        emptyLabel.textColor = Theme.Color.textTertiary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        captionLabel.stringValue = caption
        captionLabel.font = Theme.Font.mono
        captionLabel.textColor = Theme.Color.textSecondary
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalPreviewView is created in code, never from a nib")
    }

    /// Keeps the Metal layer letterboxed to 4:3 inside whatever box the grid gives us.
    override func layout() {
        super.layout()
        guard let metalLayer else { return }

        let aspect = Theme.Metrics.previewAspectRatio
        var size = bounds.size
        if size.width / max(size.height, 1) > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        let frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
        // Setting drawableSize from the layer's own bounds keeps one drawable pixel
        // per screen pixel; see contentsScale above.
        metalLayer.frame = frame
        metalLayer.drawableSize = CGSize(width: max(frame.width, 1), height: max(frame.height, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        present()
    }

    /// Draws the current texture into the layer. Safe to call when there is nothing
    /// to draw: it simply leaves the empty state visible.
    func present() {
        emptyLabel.isHidden = texture != nil

        guard let context = MetalContext.shared,
              let metalLayer,
              let texture,
              let drawable = metalLayer.nextDrawable() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "preview '\(caption)' could not encode its draw")
            return
        }
        encoder.setRenderPipelineState(context.blitPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
