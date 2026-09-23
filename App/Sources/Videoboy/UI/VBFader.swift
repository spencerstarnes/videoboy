//
//  VBFader.swift — the custom fader used everywhere a value is set.
//
//  Purpose : `NSSlider` does not read at a glance on a dense control surface: the
//            track is a hairline, there is no fill to show travel, and the knob is a
//            small circle that disappears against the panel. This is the replacement
//            — a thick track, a filled portion showing position, and a cap that
//            overhangs the track the way a DJ fader's does.
//  Inputs  : a value and a range; mouse drags and clicks.
//  Outputs : `doubleValue`, and target/action on every change, so it drops in where
//            an `NSSlider` was.
//  Connects: Controls.fader builds these; every panel uses them.
//  Extend  : geometry lives in Theme.Fader, never here. If a size needs changing it
//            is a token change, not an edit to this file.
//
//  It is an `NSControl` subclass rather than a styled `NSSlider` because the parts
//  that matter — track thickness, fill, cap overhang — are exactly the parts
//  `NSSlider` does not expose. Subclassing it would mean fighting its drawing on
//  every OS update.
//

import AppKit
import VideoboyCore

/// A horizontal fader with a filled track and an overhanging cap.
final class VBFader: NSControl {

    /// Current value, clamped to the range. Setting it redraws but does not fire
    /// the action — programmatic changes are not user changes.
    var value: Double = 0.5 {
        didSet {
            value = min(max(value, minimum), maximum)
            needsDisplay = true
        }
    }

    var minimum: Double = 0
    var maximum: Double = 1

    /// Moves the bar to show a value something else is driving.
    ///
    /// Ignored while the fader is being dragged: a hand on the control wins over an
    /// LFO writing to the same parameter, or the bar fights the finger.
    func setDisplayedValue(_ normalised: Double) {
        guard !isDragging else { return }
        let target = minimum + normalised * (maximum - minimum)
        guard abs(target - value) > 0.0005 else { return }
        value = target
    }

    /// Drawn behind the fill. Used to tint a fader with its bus identity.
    var accentColor: NSColor = Theme.Color.accent {
        didSet { needsDisplay = true }
    }

    /// When true the fill grows from the centre rather than from the left. Right for
    /// a bipolar control such as a crossfader, where the middle is the neutral point.
    var fillsFromCentre = false {
        didSet { needsDisplay = true }
    }

    /// Highlighted while Shift is held, to show it is mappable (SPEC 7).
    var isDetectHighlighted = false {
        didSet { needsDisplay = true }
    }

    /// True when MIDI, audio or an LFO is driving this parameter.
    ///
    /// A driven parameter moves on its own, and a control that moves on its own with
    /// nothing to say why is alarming. Marking it says the movement is intended and,
    /// just as usefully, says which controls are already spoken for when you are
    /// deciding where to put the next mapping.
    var isDriven = false {
        didSet { if isDriven != oldValue { needsDisplay = true } }
    }

    /// Beat phase, 0 at the beat and rising to 1 before the next one.
    var pulsePhase: Double = 0 {
        didSet { if isDriven { needsDisplay = true } }
    }

    /// What this fader controls, so shift-clicking it can arm a mapping.
    ///
    /// Every fader carries its own address rather than the panel remembering which
    /// is which: that is the whole point of param codes, and it means shift-detect
    /// works on a fader without the panel having to know about detect at all.
    var mappingSlot: String?
    /// The effect card this fader belongs to, when it is on one. Two cards can share
    /// a param code (two ISF effects with an `amount`), so the code alone does not say
    /// which card — and so which slot — a movement is for.
    var ownerCard: String?

    // MARK: Sweep marks
    //
    // Command-option click marks an IN point, a second marks an OUT, and the fader
    // then plays itself between the two on the clock.
    //
    // This modifier pair has been through two others, and both were rejected for
    // reasons worth keeping written down:
    //
    //   SHIFT-COMMAND — shift alone already means "arm this for detect", so the two
    //   gestures shared a modifier and the order they were tested in was load-bearing.
    //
    //   CONTROL-COMMAND — macOS promotes a CONTROL-click to a RIGHT-click at the
    //   window server, so the gesture could arrive as `rightMouseDown` and never
    //   reach `mouseDown`. That needed a second entry point to catch, and a synthetic
    //   test could not tell you it was needed, because calling the handler directly
    //   bypasses the promotion.
    //
    // Option does neither. It is not spoken for by detect and it is not promoted, so
    // one check on one entry point is genuinely enough — which is why the
    // rightMouseDown override that control-command required is gone rather than left
    // behind as harmless.

    /// The first mark, if one has been set.
    private(set) var sweepFirst: Double?
    /// The second mark. Both present means the sweep is armed.
    private(set) var sweepSecond: Double?

    /// The armed sweep, if there is one.
    var sweep: ParameterSweep? {
        guard let first = sweepFirst, let second = sweepSecond else { return nil }
        let candidate = ParameterSweep(
            first: first, second: second,
            beatsPerCycle: SweepRate.beatsPerCycle(sweepRate) ?? 4)
        return candidate.isUsable ? candidate : nil
    }

    /// Which rung of the shared ladder the sweep runs at.
    var sweepRate: PlaybackTiming = .stepped(subdivision: .whole, frames: 1) {
        didSet { onSweepChanged?() }
    }

    /// Called whenever the marks or the rate change, so the row can show or hide its
    /// STEP key and the controller can start or stop driving this fader.
    var onSweepChanged: (() -> Void)?

    /// Whether the mark-a-sweep gesture is currently held, so this fader should
    /// advertise that it can take one. Set for every mappable fader at once.
    var isSweepArming = false {
        didSet {
            guard isSweepArming != oldValue else { return }
            if isSweepArming { startArmingPulse() } else { stopArmingPulse() }
            needsDisplay = true
        }
    }

    private var armingPulseTimer: Timer?
    private var armingPhase: Double = 0

    private func startArmingPulse() {
        armingPulseTimer?.invalidate()
        armingPhase = 0
        // Held for a second or two at a time, so a modest rate is plenty and it does
        // not become the busiest thing on screen.
        armingPulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.armingPhase += 1.0 / 20.0
            self.needsDisplay = true
        }
    }

    private func stopArmingPulse() {
        armingPulseTimer?.invalidate()
        armingPulseTimer = nil
    }

    deinit { armingPulseTimer?.invalidate() }

    /// Both marks, for checks that need to see where they landed.
    var sweepMarksForChecks: (first: Double?, second: Double?) { (sweepFirst, sweepSecond) }

    /// Every fader beneath a view, for finding the armed ones.
    static func all(in view: NSView) -> [VBFader] {
        var found: [VBFader] = []
        if let fader = view as? VBFader { found.append(fader) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    /// Sets both marks directly, for checks that need an armed fader without
    /// synthesising two modified clicks.
    func markSweepForChecks(first: Double, second: Double) {
        sweepFirst = first
        sweepSecond = second
        needsDisplay = true
        onSweepChanged?()
    }

    /// Clears both marks. Exposed to the responder chain so the row's ✕ can call it.
    @objc func clearSweep() {
        guard sweepFirst != nil || sweepSecond != nil else { return }
        sweepFirst = nil
        sweepSecond = nil
        needsDisplay = true
        onSweepChanged?()
    }
    var mappingCode: ParamCode?

    /// Called when the fader is shift-clicked while detect is available.
    var onDetectRequested: ((String, ParamCode) -> Void)?

    /// True while the user is dragging, so the cap can grow slightly.
    private var isDragging = false

    /// Tints for the two ends of the travel.
    ///
    /// A crossfader between two named buses should say which end is which without a
    /// label: the track carries each bus's colour on its own side, and the fill
    /// takes the colour of whichever side is winning. Nil leaves the track neutral,
    /// which is right for an ordinary parameter with no "sides".
    var leadingTint: NSColor?
    var trailingTint: NSColor?

    /// How far from the middle a position is, 0 at the centre and 1 at either end.
    ///
    /// Centre-filling faders read from the middle outwards; the others fill from one
    /// end, and for those "full" is the committed end rather than the midpoint.
    static func commitment(of value: Double) -> Double {
        min(max(abs(value - 0.5) * 2, 0), 1)
    }

    /// A colour desaturated toward neutral grey.
    ///
    /// Toward grey of the SAME brightness rather than toward a fixed grey, so the
    /// track keeps its weight as the colour drains out of it — fading to a lighter or
    /// darker neutral would read as the fill changing size.
    static func saturated(_ colour: NSColor, by amount: Double) -> NSColor {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return colour }
        let brightness = 0.299 * rgb.redComponent
            + 0.587 * rgb.greenComponent
            + 0.114 * rgb.blueComponent
        let mix = CGFloat(min(max(amount, 0), 1))
        return NSColor(
            srgbRed: brightness + (rgb.redComponent - brightness) * mix,
            green: brightness + (rgb.greenComponent - brightness) * mix,
            blue: brightness + (rgb.blueComponent - brightness) * mix,
            alpha: rgb.alphaComponent
        )
    }

    /// Overrides the track thickness. The primary crossfader is the heaviest control
    /// in the window and reads as such; a parameter fader does not need to.
    var trackHeightOverride: CGFloat?

    /// A shorter, thinner variant for places where the fader is more readout than
    /// control — a shuttle's scrub track, for instance.
    var isCompact = false {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var trackHeight: CGFloat {
        if let trackHeightOverride { return trackHeightOverride }
        return isCompact ? Theme.Fader.trackHeight * 0.6 : Theme.Fader.trackHeight
    }

    private var capWidth: CGFloat {
        isCompact ? Theme.Fader.capWidth * 0.7 : Theme.Fader.capWidth
    }

    private var capBaseHeight: CGFloat {
        if isCompact { return Theme.Fader.compactHeight }
        // The cap must always stand PROUD of its track. It was a fixed 17pt while the
        // primary crossfader's track had grown to 18, so on the one fader where the
        // overhang matters most the cap was recessed into the slot — the opposite of
        // the intent, and the reason that control looked slightly wrong without it
        // being obvious why.
        return max(Theme.Fader.capHeight, trackHeight + Theme.Fader.capOverhang)
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// Position as 0...1 along the track.
    private var normalisedValue: Double {
        let span = maximum - minimum
        guard span > 0 else { return 0 }
        return (value - minimum) / span
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// The control is as tall as its cap, so the overhang is never clipped.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: capBaseHeight)
    }

    // MARK: - Geometry

    /// The track, centred vertically and inset so the cap never runs off the ends.
    private var trackRect: NSRect {
        let inset = capWidth / 2
        return NSRect(
            x: inset,
            y: (bounds.height - trackHeight) / 2,
            width: max(bounds.width - inset * 2, 1),
            height: trackHeight
        )
    }

    /// Centre x of the cap for the current value.
    private var capCentreX: CGFloat {
        trackRect.minX + trackRect.width * CGFloat(normalisedValue)
    }

    // MARK: - Drawing

    /// Whether an event is the mark-a-sweep-point gesture.
    private func isSweepGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.option)
            && event.modifierFlags.contains(.command)
            && mappingSlot != nil
            && mappingCode != nil
    }

    /// First command-option click sets the in point, the second sets the out point,
    /// and a third starts again — so the gesture that arms a sweep is also the one
    /// that re-aims it, with no separate clear to remember.
    private func markSweepPoint(at point: NSPoint) {
        let position = valueForPoint(point)
        if sweepFirst == nil {
            sweepFirst = position
        } else if sweepSecond == nil {
            sweepSecond = position
        } else {
            sweepFirst = position
            sweepSecond = nil
        }
        needsDisplay = true
        onSweepChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = trackHeight / 2
        let dimmed = isEnabled ? 1.0 : Theme.Fader.disabledAlpha

        // Track. With tints set, each half carries its bus's colour at low strength —
        // enough to know which way you are heading without competing with the picture.
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        Theme.Color.faderTrack.withAlphaComponent(
            Theme.Color.faderTrack.alphaComponent * dimmed).setFill()
        trackPath.fill()

        // The sweep marks, drawn over the track and under everything else. A single
        // mark shows as a tick — the gesture is half finished and should look it —
        // and a pair fills the span between them.
        if let first = sweepFirst {
            func x(_ v: Double) -> CGFloat {
                let span = maximum - minimum
                let fraction = span > 0 ? (v - minimum) / span : 0
                return track.minX + track.width * CGFloat(min(max(fraction, 0), 1))
            }
            Theme.Color.sweepMark.withAlphaComponent(
                Theme.Color.sweepMark.alphaComponent * dimmed).setFill()
            if let second = sweepSecond {
                let from = min(x(first), x(second))
                let to = max(x(first), x(second))
                NSBezierPath(
                    roundedRect: NSRect(x: from, y: track.minY, width: to - from, height: track.height),
                    xRadius: radius, yRadius: radius
                ).fill()
            } else {
                NSBezierPath(rect: NSRect(
                    x: x(first) - 1, y: track.minY - 2,
                    width: 2, height: track.height + 4)).fill()
            }
        }

        if let leadingTint, let trailingTint {
            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()
            let half = track.width / 2
            let commitment = Self.commitment(of: normalisedValue)
            Self.saturated(leadingTint, by: commitment)
                .withAlphaComponent(Theme.Fader.trackTintAlpha * dimmed).setFill()
            NSBezierPath(rect: NSRect(
                x: track.minX, y: track.minY, width: half, height: track.height)).fill()
            Self.saturated(trailingTint, by: commitment)
                .withAlphaComponent(Theme.Fader.trackTintAlpha * dimmed).setFill()
            NSBezierPath(rect: NSRect(
                x: track.midX, y: track.minY, width: half, height: track.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Fill. From the left normally; from the centre for a bipolar control, so a
        // crossfader shows how far it has been pushed from neutral rather than how
        // far it is from one end.
        //
        // NOT DRAWN while a sweep is armed. The purple span between the marks is what
        // the fader is saying then, and the ordinary fill runs underneath it from the
        // left edge — two bars overlapping, one of which is answering a question
        // nobody is asking of an automated fader.
        let isSweeping = sweep != nil
        let fillRect: NSRect
        if fillsFromCentre {
            let centre = track.midX
            let x = min(centre, capCentreX)
            fillRect = NSRect(x: x, y: track.minY, width: abs(capCentreX - centre), height: track.height)
        } else {
            fillRect = NSRect(
                x: track.minX, y: track.minY,
                width: max(capCentreX - track.minX, 0), height: track.height)
        }
        if fillRect.width > 0.5 {
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            // The fill takes the colour of the side being travelled toward, so the
            // control answers "which bus am I on" at a glance and while moving.
            let fillColour: NSColor
            if let leadingTint, let trailingTint {
                fillColour = normalisedValue >= 0.5 ? trailingTint : leadingTint
            } else {
                fillColour = accentColor
            }
            // Saturation follows commitment. At the ends the bus colour is full; at
            // the centre it washes out to neutral grey, because the middle of a
            // crossfader is precisely where neither bus owns the picture. The colour
            // then reports how far you have gone as well as which way, and a fader
            // parked in the middle stops shouting a colour it has not earned.
            Self.saturated(fillColour, by: Self.commitment(of: normalisedValue))
                .withAlphaComponent(dimmed).setFill()
            if !isSweeping { fillPath.fill() }
        }

        // Cap. Taller than the track on purpose — that overhang is what makes the
        // position readable in peripheral vision, which is the whole point.
        let capHeight = capBaseHeight + (isDragging ? Theme.Fader.capDragGrowth : 0)
        let capRect = NSRect(
            x: capCentreX - capWidth / 2,
            y: (bounds.height - capHeight) / 2,
            width: capWidth,
            height: capHeight
        )
        let capPath = NSBezierPath(
            roundedRect: capRect,
            xRadius: Theme.Fader.capCornerRadius,
            yRadius: Theme.Fader.capCornerRadius
        )

        // A shadow under the cap lifts it off the track. Without it the cap reads as
        // a gap in the fill rather than as an object sitting on top of it.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55 * dimmed)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Theme.Color.faderCap.withAlphaComponent(dimmed).setFill()
        capPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A centre line down the cap, as a real fader cap has.
        let lineRect = NSRect(
            x: capRect.midX - Theme.Fader.capLineWidth / 2,
            y: capRect.minY + Theme.Fader.capLineInset,
            width: Theme.Fader.capLineWidth,
            height: capRect.height - Theme.Fader.capLineInset * 2
        )
        Theme.Color.faderCapLine.withAlphaComponent(dimmed).setFill()
        NSBezierPath(rect: lineRect).fill()

        // A driven parameter carries a standing outline that breathes on the beat.
        // The outline is what says "something is driving this" at a glance; the
        // breathing is what ties it to the music rather than leaving it a static
        // decoration. Drawn BELOW the detect highlight so holding Shift still reads
        // clearly over the top of it.
        if isDriven {
            let decay = pow(1.0 - min(max(pulsePhase, 0), 1), 2.0)
            let alpha = Theme.Pulse.drivenBaseAlpha
                + decay * (1.0 - Theme.Pulse.drivenBaseAlpha)
            Theme.Color.accent.withAlphaComponent(alpha * dimmed).setStroke()
            let outline = NSBezierPath(roundedRect: trackRect.insetBy(dx: -1.5, dy: -1.5),
                                       xRadius: trackRect.height / 2 + 1.5,
                                       yRadius: trackRect.height / 2 + 1.5)
            outline.lineWidth = Theme.Pulse.drivenLineWidth
            outline.stroke()
        }

        // The arming outline, pulsing, on every fader that could take a mark. Drawn
        // before the detect highlight so holding both modifiers still reads as
        // detect, which is the gesture with the narrower meaning.
        if isSweepArming {
            let pulse = 0.45 + 0.55 * (0.5 - 0.5 * cos(2 * Double.pi * armingPhase))
            Theme.Color.sweepArming.withAlphaComponent(pulse * dimmed).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            outline.stroke()
        }

        if isDetectHighlighted {
            Theme.Color.detectHighlight.setStroke()
            let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                         xRadius: 3, yRadius: 3)
            highlight.lineWidth = 1
            highlight.stroke()
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }

        if isSweepGesture(event) {
            markSweepPoint(at: convert(event.locationInWindow, from: nil))
            return
        }

        // Shift-click arms a mapping instead of moving the fader. Holding shift
        // already highlights every mappable control, so this is the second half of
        // the same gesture (SPEC 7).
        if event.modifierFlags.contains(.shift),
           let slot = mappingSlot, let code = mappingCode {
            onDetectRequested?(slot, code)
            return
        }

        isDragging = true
        setValue(fromPoint: convert(event.locationInWindow, from: nil))

        // Track the drag here rather than relying on mouseDragged, so the fader keeps
        // following the pointer even when it leaves the control's bounds — which it
        // will, constantly, on a fader this thin.
        var keepGoing = true
        while keepGoing {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                setValue(fromPoint: convert(next.locationInWindow, from: nil))
            case .leftMouseUp:
                keepGoing = false
            default:
                break
            }
        }
        isDragging = false
        needsDisplay = true
    }

    /// Sets the value from a point in this view's coordinates and fires the action.
    /// Where a point on the track sits in value terms. Shared by dragging and by
    /// sweep marking so the two cannot disagree about where a click landed.
    private func valueForPoint(_ point: NSPoint) -> Double {
        let track = trackRect
        guard track.width > 0 else { return value }
        let fraction = Double((point.x - track.minX) / track.width)
        return minimum + min(max(fraction, 0), 1) * (maximum - minimum)
    }

    private func setValue(fromPoint point: NSPoint) {
        let track = trackRect
        guard track.width > 0 else { return }
        let newValue = valueForPoint(point)
        guard newValue != value else { return }
        value = newValue
        sendAction(action, to: target)
    }

    // MARK: - NSControl bridging
    //
    // Panels were written against NSSlider's `doubleValue`, so the same name means
    // they do not all have to change at once.

    override var doubleValue: Double {
        get { value }
        set { value = newValue }
    }

    override var floatValue: Float {
        get { Float(value) }
        set { value = Double(newValue) }
    }

    /// Faders are keyboard-reachable like any other control.
    override var acceptsFirstResponder: Bool { isEnabled }

    /// A fader is a performance control, so it acts on the first click even when the
    /// window is not key — the same rule as the transport and step keys. Without it,
    /// the first grab after touching the output window or Preferences only activated
    /// the main window and the fader did not move. Found by `selfqa mosh`, which
    /// clicks through a window that is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return super.keyDown(with: event) }
        // A fine step, so arrow keys are useful for trimming rather than jumping.
        let step = (maximum - minimum) * Theme.Fader.keyboardStep
        switch event.keyCode {
        case 123, 125:  // left, down
            value -= step
            sendAction(action, to: target)
        case 124, 126:  // right, up
            value += step
            sendAction(action, to: target)
        default:
            super.keyDown(with: event)
        }
    }
}
