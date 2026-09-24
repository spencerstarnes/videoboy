//
//  VBOptionButton.swift — the compact lit toggle used along the output bar.
//
//  Purpose : The bar was caption-plus-NSSwitch pairs. Each pair is a 28pt switch, a
//            word, and the gap between them — three elements to say one boolean, six
//            times over, which is what made the strip chunky. Resolve, FCP X and
//            Photoshop all answer this the same way: a small button carrying its own
//            label, lit when on. One element, no caption, and the state is the
//            colour rather than the position of a knob.
//  Inputs  : a title, and whether it is on.
//  Outputs : a click, and a right-click when the option has settings behind it.
//  Connects: SettingsBarPanelBody, Theme.
//  Extend  : options with detail behind them use the CONTEXT MENU, never a chevron.
//            A truncated mini popup next to a toggle is two controls where one will
//            do, and it is the thing that made this bar look busy.
//
//  Sized from AppKit's own mini metrics (16pt) rather than invented numbers, so it
//  sits correctly beside the system controls it shares the bar with.
//

import AppKit
import VideoboyCore

/// A small toggle that carries its own label and lights when on.
final class VBOptionButton: NSControl {

    private(set) var title: String

    /// Changes the label, for keys that cycle through states.
    func setTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A key that is on only while held: the action fires on the press (on) and
    /// again on the release (off), like a pad. For triggers — the datamosh HEAL —
    /// where firing on the way DOWN is what keeps a hit on the beat.
    var isMomentary = false

    /// The colour of the lit state. Defaults to the accent; the output enable uses
    /// tally red, because that one means "on air" rather than "option selected".
    var onColour: NSColor = Theme.Color.accent

    /// Called on right-click, for options that have settings behind them.
    var onSecondaryClick: ((NSView) -> Void)?

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String, onColour: NSColor = Theme.Color.accent) {
        self.title = title
        self.onColour = onColour
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Matches the bus keys' height, for the keys that sit beside them.
    ///
    /// Per instance rather than for the whole type: the transport keys on a fader
    /// panel belong to the same row as A and B and should read as the same kind of
    /// thing, while the output bar's toggles are a settings strip that was
    /// deliberately made slim and should stay that way.
    var isTall = false {
        didSet {
            guard isTall != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let text = title as NSString
        let width = text.size(withAttributes: [.font: Theme.Font.tinyLabel]).width
        return NSSize(
            width: ceil(width) + Theme.OptionButton.horizontalPadding * 2,
            height: isTall ? Theme.BusButton.height : Theme.OptionButton.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    /// Every option button beneath a view.
    static func all(in view: NSView) -> [VBOptionButton] {
        var found: [VBOptionButton] = []
        if let key = view as? VBOptionButton { found.append(key) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    // MARK: Detect
    //
    // An action key can be learned to a MIDI button exactly as a fader can be learned
    // to a knob. The gesture is the same one — hold Shift, click the control — so a
    // performer does not have to know which kind of thing they are pointing at.

    /// The slot and code this key stands for, when it can be learned.
    var mappingSlot: String?
    var mappingCode: ParamCode?

    /// Called when the key is shift-clicked while detect is available.
    var onDetectRequested: ((String, ParamCode) -> Void)?

    // MARK: Automation
    //
    // A key can be automated as well as learned. There is nothing to sweep BETWEEN on
    // a button, so automation here means flipping on the beat at a chosen rate — the
    // same ladder the shuttle and the fader sweeps walk, so one control idea covers
    // faders and buttons rather than two.

    /// How often this key flips, or nil when it is not automated.
    var flipRate: PlaybackTiming? {
        didSet {
            guard flipRate != oldValue else { return }
            needsDisplay = true
            onFlipRateChanged?()
        }
    }

    /// Called when the automation rate changes, so the panel can show its controls
    /// and the controller can start or stop flipping it.
    var onFlipRateChanged: (() -> Void)?

    /// Whether this key is currently flipping on the beat.
    var isAutomated: Bool {
        guard let flipRate else { return false }
        return SweepRate.beatsPerCycle(flipRate) != nil
    }

    /// Lit while Shift is held and this key can be learned.
    var isDetectHighlighted = false {
        didSet {
            guard isDetectHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether the mark-a-sweep gesture (⌘⌥ held) is currently offered on this key.
    /// Same pulsing outline `VBFader` shows while a sweep can be marked, so the ONE
    /// gesture reads the same everywhere it works rather than a button just sitting
    /// there with no sign it is about to do something different than a plain click.
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

    /// A performance key must act on the first click even when the window is not
    /// key — otherwise the click after switching from another app only activates
    /// the window and CUT silently does nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Command-option arms automation, the same gesture that marks a sweep on a
        // fader. A button has no range to mark, so one press is the whole gesture.
        if !isMomentary, event.modifierFlags.contains(.option), event.modifierFlags.contains(.command) {
            flipRate = isAutomated ? nil : .stepped(subdivision: .whole, frames: 1)
            return
        }
        if event.modifierFlags.contains(.shift),
           let slot = mappingSlot, let code = mappingCode {
            onDetectRequested?(slot, code)
            return
        }
        guard isEnabled else { return }
        if isMomentary {
            trackMomentaryPress()
            return
        }
        isPressed = true
        needsDisplay = true

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if isPressed != inside {
                isPressed = inside
                needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }

        let fired = isPressed
        isPressed = false
        if fired {
            isOn.toggle()
            sendAction(action, to: target)
        }
        needsDisplay = true
    }

    /// Momentary: on (and the action) at the press, off (and the action) at the
    /// release, wherever the pointer is by then — a pad cannot be dragged off.
    private func trackMomentaryPress() {
        isPressed = true
        isOn = true
        sendAction(action, to: target)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        isOn = false
        sendAction(action, to: target)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        onSecondaryClick(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.OptionButton.cornerRadius,
            yRadius: Theme.OptionButton.cornerRadius)

        // Lit means on. Off is a hairline outline rather than a filled slab, so a bar
        // of mostly-off options reads as quiet instead of as a row of grey blocks.
        if isOn {
            var fill = onColour
            if isPressed { fill = fill.blended(withFraction: 0.3, of: .black) ?? fill }
            else if isHovering { fill = fill.blended(withFraction: 0.15, of: .white) ?? fill }
            fill.setFill()
            path.fill()
        } else {
            if isPressed || isHovering {
                NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.09).setFill()
                path.fill()
            }
            Theme.Color.panelBorder.setStroke()
            path.lineWidth = Theme.Metrics.hairline
            path.stroke()
        }

        // An automated key carries the same purple an animating fader does, so
        // "this is moving on its own" looks the same wherever it appears.
        if isAutomated {
            Theme.Color.sweepMark.setStroke()
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: Theme.OptionButton.cornerRadius,
                yRadius: Theme.OptionButton.cornerRadius)
            outline.lineWidth = 1.5
            outline.stroke()
        }

        // The arming outline, pulsing, exactly as a fader's sweep-arm does — drawn
        // BEFORE the detect highlight so holding both modifiers still reads as
        // detect, the gesture with the narrower meaning (same rule VBFader follows).
        if isSweepArming {
            let pulse = 0.45 + 0.55 * (0.5 - 0.5 * cos(2 * Double.pi * armingPhase))
            Theme.Color.sweepArming.withAlphaComponent(pulse).setStroke()
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Theme.OptionButton.cornerRadius, yRadius: Theme.OptionButton.cornerRadius)
            outline.lineWidth = 1.5
            outline.stroke()
        }

        // The same ring a fader draws while Shift is held (SPEC 7). Without this the
        // key still LEARNS a Shift-click — `mouseDown` never checked this flag — but
        // gives no visible sign it is one of the controls Shift is offering, which
        // looks exactly like "buttons cannot be mapped" from the performer's chair.
        if isDetectHighlighted {
            Theme.Color.detectHighlight.setStroke()
            let highlight = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Theme.OptionButton.cornerRadius, yRadius: Theme.OptionButton.cornerRadius)
            highlight.lineWidth = 1.5
            highlight.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.tinyLabel,
            .foregroundColor: isOn
                ? NSColor.white
                : Theme.Color.textSecondary.withAlphaComponent(isEnabled ? 1 : 0.4)
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes)
    }
}
