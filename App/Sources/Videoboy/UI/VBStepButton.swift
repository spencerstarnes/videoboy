//
//  VBStepButton.swift — the shuttle's step-rate key, on a DJ deck's rules.
//
//  Purpose : Step playback was a popup listing seven presets. A popup is the wrong
//            shape for this: the rates are a LADDER, you move along it by feel while
//            watching the picture, and opening a menu to do that takes your eyes off
//            the thing you are timing against. Numark's decks solve it with one key —
//            it reads STEP when off, clicking walks toward faster, control-clicking
//            walks toward slower.
//  Inputs  : clicks, right-clicks and control-clicks.
//  Outputs : a `PlaybackTiming`.
//  Connects: every beat-rate key in the app — the source panels' STEP key, the
//            CUT/FADE/BEAT tap rates, the crossfaders' and effect faders' sweep
//            rates — and PlaybackTiming's two ladders. There is ONE of these, so
//            they cannot behave differently (owner, 2026-09-28: "absolutely 100%
//            universal across all uses… always editable… both forward and backwards").
//  Extend  : a new rung is an entry in `PlaybackTiming.slowLadder` or `fastLadder`.
//            Do not add a rung to both — the two halves must stay disjoint or a click
//            and a control-click can land on the same rate and the ladder stalls.
//
//  THE ONE RULE, for every key: the rungs are a line, slowest to fastest —
//  8/1 4/1 2/1 [STEP] 1/1 1/2 1/4 1/8 1/16. Click steps one rung FASTER; right-click
//  (or Control-click) steps one rung SLOWER. A step past either end lands on the
//  key's HOME rung and carries on from there. Only the source key has STEP (off) on
//  its line — for a clip, "play normally" is a real choice. A rate key (tap or sweep)
//  never offers off: a rate of "no rate" disarmed the button it belonged to and hid
//  the key mid-gesture, or stalled the sweep — the key was there, then not editable.
//  Its home is 1/1. Turning the automation off is its own gesture (✕, ⌥⌘-click).
//

import AppKit
import VideoboyCore

/// One key that walks the step-rate ladder in both directions.
final class VBStepButton: NSControl, AuditableControl {

    /// Called whenever the rate changes.
    var onTimingChanged: ((PlaybackTiming) -> Void)?

    /// Driven by a closure rather than target/action, so it answers for itself.
    var isWiredForAudit: Bool { onTimingChanged != nil }

    /// Whether STEP (off) is a rung — true only for the source panels' step key.
    /// Set it before the key is used; everything else here follows from it.
    var allowsOff = true {
        didSet { setTiming(timing) }
    }

    /// The rungs this key walks, slowest first.
    private var rungs: [PlaybackTiming] {
        PlaybackTiming.slowLadder.reversed() + (allowsOff ? [.continuous] : []) + PlaybackTiming.fastLadder
    }

    /// Where a step past either end lands: STEP when it is a rung, else 1/1.
    private var homeIndex: Int {
        rungs.firstIndex(of: allowsOff ? .continuous : PlaybackTiming.fastLadder[0]) ?? 0
    }

    /// Index into `rungs`.
    private lazy var index = homeIndex

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    /// The timing this key currently represents.
    var timing: PlaybackTiming { rungs[min(max(index, 0), rungs.count - 1)] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Step rate. Click for faster, right-click for slower."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 52, height: Theme.OptionButton.height)
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

    /// Acts on the first click into an inactive window, same as the keys beside it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Control-click is the same gesture as a right-click on this platform, and
        // both mean "the other way" here.
        if event.modifierFlags.contains(.control) {
            step(by: -1)
        } else {
            step(by: 1)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        step(by: -1)
    }

    /// Moves one rung: +1 faster, -1 slower. Past either end, home.
    private func step(by direction: Int) {
        let next = index + direction
        index = rungs.indices.contains(next) ? next : homeIndex
        needsDisplay = true
        Log.info(.app, "beat rate is now \(timing.displayName)")
        onTimingChanged?(timing)
    }

    /// Sets the key without firing its callback, for restoring saved state and for
    /// following a rate changed elsewhere. A timing that is not on this key's line
    /// (STEP on a rate key) shows as home rather than leaving the key stale.
    func setTiming(_ timing: PlaybackTiming) {
        index = rungs.firstIndex(of: timing) ?? homeIndex
        needsDisplay = true
    }

    /// Steps as a click (+1) or right-click (-1) would — for checks, which cannot
    /// deliver a real right-click to a window that is not key.
    func stepForChecks(_ direction: Int) { step(by: direction) }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.OptionButton.cornerRadius,
            yRadius: Theme.OptionButton.cornerRadius)

        // Lit whenever stepping is ON, so a glance says whether this clip is running
        // or holding — which is the question, not what the rate happens to be.
        let isStepping = timing != .continuous
        if isStepping {
            var fill = Theme.Color.accent
            if isPressed { fill = fill.blended(withFraction: 0.3, of: .black) ?? fill }
            else if isHovering { fill = fill.blended(withFraction: 0.15, of: .white) ?? fill }
            fill.setFill()
            path.fill()
        } else {
            if isHovering {
                NSColor.white.withAlphaComponent(0.09).setFill()
                path.fill()
            }
            Theme.Color.panelBorder.setStroke()
            path.lineWidth = Theme.Metrics.hairline
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.osd(size: 10),
            .foregroundColor: isStepping ? NSColor.white : Theme.Color.textSecondary
        ]
        let text = timing.displayName as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes)
    }
}
