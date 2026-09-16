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

    /// Draws the action-safe and title-safe rectangles over the picture (SPEC 11).
    var showsSafeZones = false {
        didSet { updateOverlays() }
    }

    /// Overscan amount, 0...1. Shown as the boundary of what a CRT would actually
    /// display, so the operator can see what is about to be lost.
    var overscan = 0.0 {
        didSet { updateOverlays() }
    }

    /// The per-preview record arm indicator, upper right. Nil for previews that are
    /// not a recordable feed.
    private(set) var recordIndicator: MiniRecordIndicator?

    private let captionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "no source")
    private var metalLayer: CAMetalLayer?
    private let overlayLayer = CAShapeLayer()

    /// The scope image drawn over the picture, when scopes are on for this preview.
    private let scopeLayer = CALayer()

    /// Zebra stripes drawn over the picture, marking illegal levels.
    private let zebraLayer = CALayer()

    /// - Parameters:
    ///   - caption: overlay text, e.g. "A" or "720x480 · 480i".
    ///   - recordLabel: the feed's letter for the arm indicator (A-D, 1, 2, P).
    ///     Nil leaves the preview without one.
    init(caption: String, recordLabel: String? = nil) {
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

        // Scope and zebra sit above the picture, below the safe-zone lines. Neither
        // intercepts clicks: they are readouts drawn on the monitor, not controls.
        scopeLayer.contentsGravity = .resize
        scopeLayer.isHidden = true
        layer?.addSublayer(scopeLayer)

        zebraLayer.contentsGravity = .resize
        zebraLayer.isHidden = true
        zebraLayer.compositingFilter = "screenBlendMode"
        layer?.addSublayer(zebraLayer)

        // Overlays sit above the picture and never intercept clicks.
        overlayLayer.fillColor = nil
        overlayLayer.lineWidth = 1
        overlayLayer.strokeColor = Theme.Color.textSecondary.cgColor
        layer?.addSublayer(overlayLayer)

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

        if let recordLabel {
            let indicator = MiniRecordIndicator(label: recordLabel)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            recordIndicator = indicator
            NSLayoutConstraint.activate([
                indicator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                indicator.widthAnchor.constraint(equalToConstant: Theme.Record.miniWidth),
                indicator.heightAnchor.constraint(equalToConstant: Theme.Record.miniHeight)
            ])
        }
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
        scopeLayer.frame = frame
        zebraLayer.frame = frame
        overlayLayer.frame = frame
        updateOverlays()
    }

    /// Rebuilds the safe-zone and overscan outlines for the current picture area.
    ///
    /// The rectangles come from `CRTGeometry`, the same source the output path uses,
    /// so what the overlay promises and what the output does cannot drift apart.
    private func updateOverlays() {
        guard let metalLayer else { return }
        let bounds = CGRect(origin: .zero, size: metalLayer.frame.size)
        guard bounds.width > 1, bounds.height > 1 else {
            overlayLayer.path = nil
            return
        }

        let path = CGMutablePath()

        if showsSafeZones {
            for rect in [CRTGeometry.actionSafe, CRTGeometry.titleSafe] {
                path.addRect(CGRect(
                    x: bounds.width * CGFloat(rect.x),
                    y: bounds.height * CGFloat(rect.y),
                    width: bounds.width * CGFloat(rect.width),
                    height: bounds.height * CGFloat(rect.height)
                ))
            }
        }

        if overscan > 0.001 {
            let visible = CRTGeometry.visibleRect(overscan: overscan)
            path.addRect(CGRect(
                x: bounds.width * CGFloat(visible.x),
                y: bounds.height * CGFloat(visible.y),
                width: bounds.width * CGFloat(visible.width),
                height: bounds.height * CGFloat(visible.height)
            ))
        }

        overlayLayer.path = path.isEmpty ? nil : path
        overlayLayer.isHidden = path.isEmpty
    }

    /// Shows a rendered scope over this preview, or clears it.
    ///
    /// The scope arrives as a finished image rather than as data to plot here: the
    /// drawing lives in Core where it can be tested by measuring its output, and this
    /// view's only job is to put it on screen.
    func setScopeImage(_ image: ImageBuffer?, dimsPicture: Bool) {
        guard let image, let cgImage = image.makeCGImage() else {
            scopeLayer.isHidden = true
            scopeLayer.contents = nil
            metalLayer?.opacity = 1
            return
        }
        scopeLayer.contents = cgImage
        scopeLayer.isHidden = false
        // Over a picture the scope needs the picture held back, or the trace is lost
        // in it. Over black there is nothing to hold back.
        metalLayer?.opacity = dimsPicture ? 0.35 : 0.0
    }

    /// Shows a zebra overlay, or clears it.
    func setZebraImage(_ image: ImageBuffer?) {
        guard let image, let cgImage = image.makeCGImage() else {
            zebraLayer.isHidden = true
            zebraLayer.contents = nil
            return
        }
        zebraLayer.contents = cgImage
        zebraLayer.isHidden = false
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
