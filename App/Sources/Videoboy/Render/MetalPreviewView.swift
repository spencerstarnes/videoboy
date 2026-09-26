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

    /// The texture to draw. Setting it does NOT schedule a redraw: every caller sets
    /// it on the render tick and calls `present()` straight after. Marking the view
    /// dirty here as well made AppKit's display pass present the frame a second
    /// time, out of phase with the tick — ~35 presents/s for 30 frames, which a
    /// moving wipe edge showed as judder. `draw(_:)` still presents on a resize or
    /// an unhide, which AppKit dirties the view for by itself.
    ///
    /// Going from nothing to a picture (or back) asks for LAYOUT, not display: the
    /// striped bars depend on whether there is a picture, and layout never presents.
    var texture: MTLTexture? {
        didSet { if (texture == nil) != (oldValue == nil) { needsLayout = true } }
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

    /// The send glyph, bottom right. macOS asks "where do you want this?" with one
    /// glyph and a short list, and everyone already knows how to use it.
    private(set) var routingButton: NSButton?

    /// Whether the send glyph is drawn on the picture.
    ///
    /// False for the composites, whose panel puts it on the bar beneath instead. Set
    /// before the view builds itself, which is why it is an init parameter rather than
    /// a property to flip afterwards.
    private let showsRoutingOverlay: Bool

    /// Called when the send glyph is clicked, with the glyph to hang a popover from.
    var onRoutingRequested: ((NSView) -> Void)?

    private let captionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "no source")
    private var metalLayer: CAMetalLayer?

    /// When each drawable actually reached the screen (seconds, host clock), recorded
    /// only while a check sets this non-nil. Nil in normal use: no handler, no cost.
    var presentedTimesForChecks: [CFTimeInterval]?
    private let overlayLayer = CAShapeLayer()

    /// The tally glow: a red neon line inside the picture's edge, whose brightness is
    /// HOW MUCH OF THIS SOURCE IS ON AIR.
    private let tallyLayer = CAShapeLayer()

    /// Caution-striped bars, drawn over the picture's bars and around a picture that
    /// does not fill the monitor. Static layers, rebuilt only when the shape changes —
    /// nothing per frame.
    private let barsLayer = CALayer()

    /// Where the picture sits inside the texture (unit rectangle, origin top-left),
    /// when the texture carries bars of its own — a 16:9 clip fitted into the 4:3
    /// canvas. Nil when the texture is all picture.
    var pictureRect: CGRect? {
        didSet { if pictureRect != oldValue { needsLayout = true } }
    }

    /// The scope image drawn over the picture, when scopes are on for this preview.
    private let scopeLayer = CALayer()

    /// The NAME / TC text block, drawn by `DataBurnRenderer` so the monitor shows
    /// exactly what DATA BURN would put on air.
    private let dataLayer = CALayer()
    /// Where `dataLayer` sits, in 0...1 of the picture, origin top left.
    private var dataRect: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0)


    /// - Parameters:
    ///   - caption: overlay text, e.g. "A" or "720x480 · 480i".
    ///   - recordLabel: the feed's letter for the arm indicator (A-D, 1, 2, P).
    ///     Nil leaves the preview without one.
    /// Whether this preview offers auto-play. True for the four sources; false for
    /// the sub-mixes and programme, which have nothing to load a clip into.
    private let showsAutoPlay: Bool

    /// - Parameter syncsToDisplay: true only for the OUTPUT window. An in-window
    ///   preview is composited by the window server at vsync anyway, so waiting for
    ///   vsync here too made every preview's `nextDrawable()` block the render tick
    ///   until the display freed a drawable — measured as ~7.5 ms per tick with seven
    ///   previews, enough to halve the frame rate. The output feeds the analog chain
    ///   directly and keeps vsync.
    init(
        caption: String, recordLabel: String? = nil, showsAutoPlay: Bool = false,
        showsRoutingOverlay: Bool = true, syncsToDisplay: Bool = false
    ) {
        self.showsAutoPlay = showsAutoPlay
        self.showsRoutingOverlay = showsRoutingOverlay
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
            metalLayer.displaySyncEnabled = syncsToDisplay
            // Standard-definition video is not HiDPI. Forcing scale 1 keeps the
            // pixel mapping exact and avoids resampling a 720x480 picture twice.
            metalLayer.contentsScale = 1.0
            layer?.addSublayer(metalLayer)
            self.metalLayer = metalLayer
            layer?.addSublayer(barsLayer)
        } else {
            Log.warn(.render, "preview '\(caption)' has no Metal device; showing empty state only")
        }

        // The scope sits above the picture, below the safe-zone lines. It does not
        // intercept clicks: it is a readout drawn on the monitor, not a control.
        scopeLayer.contentsGravity = .resize
        scopeLayer.isHidden = true
        layer?.addSublayer(scopeLayer)

        dataLayer.contentsGravity = .resize
        dataLayer.isHidden = true
        layer?.addSublayer(dataLayer)


        // Overlays sit above the picture and never intercept clicks.
        overlayLayer.fillColor = nil
        overlayLayer.lineWidth = 1
        overlayLayer.strokeColor = Theme.Color.textSecondary.cgColor
        layer?.addSublayer(overlayLayer)

        // The tally glow. Inside the picture's edge rather than around the panel,
        // because it is the PICTURE that is on air — and a broadcast tally is a lamp on
        // the thing itself, not a note about it.
        tallyLayer.fillColor = nil
        tallyLayer.strokeColor = Theme.Color.tallyOnAir.cgColor
        tallyLayer.lineWidth = 2
        tallyLayer.shadowColor = Theme.Color.tallyOnAir.cgColor
        tallyLayer.shadowOffset = .zero
        tallyLayer.shadowRadius = 5
        tallyLayer.opacity = 0
        layer?.addSublayer(tallyLayer)

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

        // The send glyph, ON THE PICTURE — for the four source previews, which have no
        // bar of their own to put it on.
        //
        // The composites do have one, and there it belongs on the bar instead: those
        // are the big pictures, they are what you actually watch, and a control sitting
        // in the corner of the thing you are watching is a control in the way. See
        // `showsRoutingOverlay`.
        if showsRoutingOverlay {
        let routing = NSButton(
            image: NSImage(
                systemSymbolName: "airplayvideo",
                accessibilityDescription: "Send this to a display") ?? NSImage(),
            target: self, action: #selector(routingPressed(_:)))
        routing.bezelStyle = .inline
        routing.isBordered = false
        routing.contentTintColor = Theme.Color.textTertiary
        routing.toolTip = "Send this to a display"
        routing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(routing)
        routingButton = routing
        NSLayoutConstraint.activate([
            routing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            routing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            routing.widthAnchor.constraint(equalToConstant: 18),
            routing.heightAnchor.constraint(equalToConstant: 14)
        ])
        }

        if let recordLabel {
            let indicator = MiniRecordIndicator(label: recordLabel)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            recordIndicator = indicator
            // Auto-play: the GLYPH ITSELF is the control, under the arm marker, and
            // only on the four sources. A checkbox beside an icon is two controls
            // saying one thing, on a picture where every pixel of chrome covers the
            // image — and a sub-mix has nothing to auto-play, since clips are loaded
            // into channels rather than into a mix.
            if showsAutoPlay {
                let autoPlay = NSButton(image: NSImage(
                    systemSymbolName: "play.fill", accessibilityDescription: "Auto-play")
                    ?? NSImage(), target: nil, action: nil)
                autoPlay.isBordered = false
                autoPlay.bezelStyle = .inline
                autoPlay.setButtonType(.toggle)
                autoPlay.imagePosition = .imageOnly
                autoPlay.translatesAutoresizingMaskIntoConstraints = false
                autoPlay.state = .on
                autoPlay.contentTintColor = Theme.Color.textPrimary
                autoPlay.toolTip = "Play this source as soon as a clip is loaded into it"
                autoPlayCheckbox = autoPlay
                addSubview(autoPlay)

                NSLayoutConstraint.activate([
                    autoPlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                    autoPlay.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 3),
                    autoPlay.widthAnchor.constraint(equalToConstant: 12),
                    autoPlay.heightAnchor.constraint(equalToConstant: 12)
                ])
            }

            NSLayoutConstraint.activate([
                indicator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                indicator.widthAnchor.constraint(equalToConstant: Theme.Record.miniWidth),
                indicator.heightAnchor.constraint(equalToConstant: Theme.Record.miniHeight)
            ])
        }
    }

    @objc private func routingPressed(_ sender: NSButton) {
        onRoutingRequested?(sender)
    }

    /// Lights the glyph while this preview is being sent somewhere, so a route is
    /// visible from the window rather than only from the popover that made it.
    func setRouted(_ isRouted: Bool) {
        routingButton?.contentTintColor = isRouted
            ? Theme.Color.accent : Theme.Color.textTertiary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalPreviewView is created in code, never from a nib")
    }

    /// How the picture is placed when its shape and the view's disagree.
    var fillMode: PreviewFill = .fit {
        didSet {
            guard fillMode != oldValue else { return }
            needsLayout = true
        }
    }

    /// Places the Metal layer inside whatever box the grid gives us.
    override func layout() {
        super.layout()
        guard let metalLayer else { return }

        // Where the picture sits inside this view, per the chosen fill mode. The
        // source is SD 4:3; the view is whatever the grid gave us, which is now also
        // 4:3 for the previews, so Fit and Fill agree and there is nothing to see —
        // the modes earn their keep on material that is not 4:3 and on the output
        // window, where the display decides the shape.
        //
        // By DISPLAY shape, not pixel count: an SD raster is 720×480 pixels but is
        // shown 4:3. Placing it by its pixel count drew every preview 12.5% too wide.
        let canvas = CanvasGeometry.standardDefinition
        let sourceSize = CGSize(width: canvas.displayAspect * CGFloat(canvas.height),
                                height: CGFloat(canvas.height))
        let placed = fillMode.rect(sourceSize: sourceSize, in: bounds.size)
        let frame = NSRect(
            x: placed.origin.x, y: placed.origin.y,
            width: placed.width, height: placed.height
        )
        // Setting drawableSize from the layer's own bounds keeps one drawable pixel
        // per screen pixel; see contentsScale above.
        metalLayer.frame = frame
        metalLayer.drawableSize = CGSize(width: max(frame.width, 1), height: max(frame.height, 1))
        // A corner scope takes a quarter of the width in the lower right, with a
        // small margin — big enough to read a waveform's shape, small enough that the
        // picture is still the thing you are looking at.
        // One rectangle, from the same `ScopePlacement` the output path uses, so what
        // the preview shows and what SEND puts on air cannot drift apart. The rect is
        // given with its origin at the TOP, as a picture is described; this layer's
        // coordinates run the other way, hence the flip.
        //
        // Placed on the part of the picture that is VISIBLE, not on the picture. Fill
        // and Centre make the picture larger than this view and let the view crop it;
        // a scope placed on the whole picture was cropped with it — at Centre a
        // 720x480 picture in a ~460-point monitor lost a third of every trace off the
        // edges. A scope is a readout of the picture, not part of it, so it must
        // always be whole.
        let visible = frame.intersection(bounds).isNull ? bounds : frame.intersection(bounds)
        let rect = scopePlacement.rect
        scopeLayer.frame = CGRect(
            x: visible.minX + visible.width * rect.x,
            y: visible.maxY - visible.height * (rect.y + rect.height),
            width: visible.width * rect.width,
            height: visible.height * rect.height)
        dataLayer.frame = CGRect(
            x: visible.minX + visible.width * dataRect.x,
            y: visible.maxY - visible.height * (dataRect.y + dataRect.height),
            width: visible.width * dataRect.width,
            height: visible.height * dataRect.height)
        overlayLayer.frame = frame
        updateBars(pictureFrame: frame)
        // The tally gets the VIEW's bounds, not the picture's.
        //
        // The picture is often cropped by the fill mode — taller or wider than what is
        // visible — so an outline drawn on IT loses whichever pair of edges falls
        // outside, which is why the first version showed only the left and right sides.
        // A broadcast tally outlines the MONITOR anyway, not the image inside it.
        tallyLayer.frame = bounds
        updateTally()
        updateOverlays()
    }

    /// Rebuilds the striped bars over the texture's own bars (from `pictureRect`).
    ///
    /// Only a PICTURE's bars are striped — a clip that is not the canvas's shape. The
    /// margin a monitor panel leaves around a correctly shaped picture is not a bar
    /// and keeps the plain empty fill; striping it put stripes on every monitor. When
    /// the canvas itself can be other than 4:3 (0.4.11), its margin joins these.
    private func updateBars(pictureFrame frame: NSRect) {
        barsLayer.frame = bounds
        var rects: [CGRect] = []
        if texture != nil {
            // Unit rect is top-down; layers are bottom-up.
            if let picture = pictureRect {
                let inner = CGRect(
                    x: frame.minX + frame.width * picture.minX,
                    y: frame.maxY - frame.height * picture.maxY,
                    width: frame.width * picture.width,
                    height: frame.height * picture.height)
                rects += [
                    CGRect(x: frame.minX, y: inner.maxY, width: frame.width, height: frame.maxY - inner.maxY),
                    CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: inner.minY - frame.minY),
                    CGRect(x: frame.minX, y: inner.minY, width: inner.minX - frame.minX, height: inner.height),
                    CGRect(x: inner.maxX, y: inner.minY, width: frame.maxX - inner.maxX, height: inner.height)
                ].map { $0.intersection(bounds) }
            }
        }
        let bars = rects.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.sublayers = bars.map { rect in
            let bar = CALayer()
            bar.frame = rect.integral
            bar.backgroundColor = Self.stripePattern
            return bar
        }
        CATransaction.commit()
    }

    /// The striped bars currently shown, in view coordinates. For self-QA.
    var barRectsForChecks: [CGRect] { barsLayer.sublayers?.map(\.frame) ?? [] }

    /// The striped bars alone, rendered to an image. For self-QA: Core Animation draws
    /// plain layers into a bitmap faithfully, unlike the Metal layer beside them.
    func renderBarsForChecks() -> ImageBuffer? {
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        barsLayer.render(in: context)
        guard let data = context.data else { return nil }
        // A bitmap context's memory starts at the TOP row, as ImageBuffer does.
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return ImageBuffer(width: width, height: height, pixels: bytes)
    }

    /// Diagonal caution stripes, grey on dark grey, as a tiling pattern colour.
    private static let stripePattern: CGColor = {
        let stripe = Theme.Metrics.barStripeWidth
        let period = stripe * 2
        let tile = NSImage(size: NSSize(width: period, height: period), flipped: false) { rect in
            Theme.Color.barStripeDark.setFill()
            rect.fill()
            Theme.Color.barStripeLight.setFill()
            // A band rising at 45°, repeated one period either side so the tile's
            // edges meet their neighbours without a seam.
            for offset in [-period, 0, period] {
                let band = NSBezierPath()
                band.move(to: NSPoint(x: offset, y: 0))
                band.line(to: NSPoint(x: offset + stripe, y: 0))
                band.line(to: NSPoint(x: offset + stripe + period, y: period))
                band.line(to: NSPoint(x: offset + period, y: period))
                band.close()
                band.fill()
            }
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

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
    /// The auto-play key, when this preview has one (the four sources do).
    private(set) weak var autoPlayCheckbox: NSButton?

    /// Paints the auto-play glyph for its state: lit when on, greyed when off.
    func setAutoPlayAppearance(on: Bool) {
        autoPlayCheckbox?.state = on ? .on : .off
        autoPlayCheckbox?.contentTintColor = on
            ? Theme.Color.textPrimary
            : Theme.Color.textTertiary.withAlphaComponent(0.45)
    }

    /// Where the scope and the NAME / TC block are drawn, in this view's coordinates,
    /// or nil while hidden. For the self-QA.
    var scopeFrameForChecks: CGRect? { scopeLayer.isHidden ? nil : scopeLayer.frame }
    var dataFrameForChecks: CGRect? { dataLayer.isHidden ? nil : dataLayer.frame }
    var pictureOpacityForChecks: Float { metalLayer?.opacity ?? 0 }

    /// Where the scope sits on the picture.
    ///
    /// Was a bool for "corner or not". Placement now has three answers and the third —
    /// the lower-third band — is not expressible as a variation of the other two.
    var scopePlacement: ScopePlacement = .full { didSet { needsLayout = true } }

    /// How much of this source is currently reaching the programme output, 0...1.
    ///
    /// ── WHY A LEVEL AND NOT A LAMP ──────────────────────────────────────────────
    ///
    /// A broadcast tally is on or off because a hard-cut mixer has no in-between. This
    /// one does: the crossfader spends most of its life between the two, and during a
    /// fade BOTH sources are genuinely on air. A lamp would have to pick a moment to
    /// come on, and whichever moment it picked would be a lie for the rest of the
    /// travel.
    ///
    /// So the glow tracks the fader. Hard left is A fully lit and B dark; halfway is
    /// both at half; hard right is the reverse. That is a true statement about the
    /// picture at every position rather than at two of them.
    ///
    /// It is also MULTIPLIED DOWN THE CHAIN: a source on a sub-mix that is itself faded
    /// out is not on air, however far up its own fader is, and showing it lit would be
    /// exactly the wrong answer to "what is on screen".
    var onAirLevel: Double = 0 {
        didSet {
            guard abs(onAirLevel - oldValue) > 0.002 else { return }
            updateTally()
        }
    }

    private func updateTally() {
        let level = min(max(onAirLevel, 0), 1)

        // The layer already sits on the picture, so its own bounds ARE the picture —
        // no second computation of where the image is, which is the kind of duplicate
        // that drifts the moment a fill mode changes.
        let frame = CGRect(origin: .zero, size: tallyLayer.bounds.size)
        guard frame.width > 2, frame.height > 2 else {
            tallyLayer.opacity = 0
            return
        }
        // Inset by the full line width so the stroke sits wholly inside — a stroke is
        // centred on its path, so an inset of half that would put the outer half of the
        // line outside the view and the layer's clip would eat it.
        let path = CGPath(
            roundedRect: frame.insetBy(dx: 2, dy: 2),
            cornerWidth: 3, cornerHeight: 3, transform: nil)

        CATransaction.begin()
        // No implicit animation: this is driven from the fader, which already moves
        // smoothly. A quarter-second layer animation on top would make the glow LAG
        // the picture it is describing.
        CATransaction.setDisableActions(true)
        tallyLayer.path = path
        // Eased so the lit end reads as fully lit well before the fader reaches the
        // stop — a linear ramp looks dim across most of its travel, because perceived
        // brightness is not linear in opacity.
        let eased = pow(level, 0.6)
        tallyLayer.opacity = Float(eased)
        tallyLayer.shadowOpacity = Float(eased * 0.9)
        CATransaction.commit()
    }

    ///
    /// - Parameters:
    ///   - pictureOpacity: how much of the picture shows behind — 1 untouched, 0 black.
    ///     `ScopeSelection.pictureDimming` decides it, the same number DATA BURN uses.
    ///   - keysOutBlack: true when the scope is drawn OVER the picture. A scope image
    ///     is traces on black; laid on as it is, the black is an opaque sheet and the
    ///     picture behind never shows, which made OVER a key that did nothing. Keyed,
    ///     black is transparent and the trace is screened on, as the burn does it.
    func setScopeImage(_ image: ImageBuffer?, pictureOpacity: Float = 1, keysOutBlack: Bool = false) {
        guard let image,
              let cgImage = (keysOutBlack ? Self.keyedOutBlack(image) : image).makeCGImage() else {
            scopeLayer.isHidden = true
            scopeLayer.contents = nil
            metalLayer?.opacity = 1
            return
        }
        scopeLayer.contents = cgImage
        scopeLayer.isHidden = false
        metalLayer?.opacity = pictureOpacity
    }

    /// The same image with each pixel's alpha set to its brightest channel.
    ///
    /// The buffer is premultiplied, so a colour no brighter than its alpha is already
    /// valid: black becomes clear, a full-brightness trace stays opaque, and the dim
    /// graticule becomes a faint line. Composited that way it is the screen blend the
    /// burn node uses. A few hundred thousand bytes, a few times a second, off the
    /// frame path's GPU work — scopes refresh at about six a second.
    private static func keyedOutBlack(_ image: ImageBuffer) -> ImageBuffer {
        var pixels = image.pixels
        pixels.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index + 3 < buffer.count {
                buffer[index + 3] = max(buffer[index], buffer[index + 1], buffer[index + 2])
                index += ImageBuffer.bytesPerPixel
            }
        }
        return ImageBuffer(width: image.width, height: image.height, pixels: pixels)
    }

    /// Shows a NAME / TC block at `rect` (0...1 of the picture, origin top left), or
    /// hides it when `image` is nil.
    func setDataImage(
        _ image: ImageBuffer?, rect: (x: Double, y: Double, width: Double, height: Double)
    ) {
        CATransaction.begin()
        // Changes every frame while a timecode ticks; an implicit fade would smear it.
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let image, let cgImage = image.makeCGImage() else {
            dataLayer.isHidden = true
            dataLayer.contents = nil
            return
        }
        dataLayer.contents = cgImage
        dataLayer.isHidden = false
        if rect != dataRect {
            dataRect = rect
            needsLayout = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        present()
    }

    /// Draws the current texture into the layer, or CLEARS the layer when there is
    /// no texture.
    ///
    /// Clearing is the part that used to be missing. This returned early on a nil
    /// texture after un-hiding the empty label, which left the last drawable still on
    /// screen — so ejecting a clip showed "no source" printed over the frame that was
    /// playing when it was ejected. A layer keeps what it was last given until it is
    /// given something else; going empty has to be drawn, not merely stopped.
    /// - Parameter time: the refresh to show this frame on (host clock), from the
    ///   render tick. Nil — a resize, an unhide — shows it as soon as it is drawn.
    ///   Scheduling does not wait: the drawable is queued and the tick carries on.
    func present(at time: CFTimeInterval? = nil) {
        emptyLabel.isHidden = texture != nil

        guard let context = MetalContext.shared, let metalLayer else { return }

        // A preview nobody can see is skipped: an uncomposited layer stops releasing
        // drawables, and `nextDrawable()` then blocks the render tick for up to 1 s —
        // which also freezes the output. The output window is exempt; it is the show.
        if !metalLayer.displaySyncEnabled,
           isHiddenOrHasHiddenAncestor
            || !(window?.occlusionState.contains(.visible) ?? false) {
            return
        }

        if texture == nil {
            clearLayer(context: context, layer: metalLayer)
            return
        }

        guard let texture, let drawable = metalLayer.nextDrawable() else { return }

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
        if presentedTimesForChecks != nil {
            drawable.addPresentedHandler { [weak self] shown in
                let time = shown.presentedTime
                DispatchQueue.main.async { self?.presentedTimesForChecks?.append(time) }
            }
        }
        if let time, time > CACurrentMediaTime() {
            commandBuffer.present(drawable, atTime: time)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    /// Presents an empty drawable, so the layer stops showing whatever it last held.
    private func clearLayer(context: MetalContext, layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
