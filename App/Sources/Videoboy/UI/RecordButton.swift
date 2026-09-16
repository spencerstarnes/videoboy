//
//  RecordButton.swift — the big red record button.
//
//  Purpose : Recording is the one control that must be findable without looking, and
//            unambiguous about whether it is running. A standard push button with a
//            red dot in its title is neither.
//  Inputs  : clicks; `isRecording` set by the app.
//  Outputs : target/action, and a clear armed/recording appearance.
//  Connects: the transport toolbar, top right.
//  Extend  : elapsed time and file size belong beside it, not inside it.
//

import AppKit

/// A round record button that reads at a glance.
final class RecordButton: NSControl {

    /// Whether recording is running. Drives the whole appearance.
    var isRecording = false {
        didSet {
            needsDisplay = true
            // The pulse is what distinguishes "recording" from "ready to record" in
            // peripheral vision, where colour alone is not enough.
            if isRecording { startPulsing() } else { stopPulsing() }
        }
    }

    private var pulseTimer: Timer?
    private var pulsePhase = 0.0
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Record"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    deinit { pulseTimer?.invalidate() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.Record.buttonDiameter, height: Theme.Record.buttonDiameter)
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

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 2
        let outer = bounds.insetBy(dx: inset, dy: inset)

        // Ring.
        let ring = NSBezierPath(ovalIn: outer.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        (isRecording ? Theme.Color.recordActive : Theme.Color.recordRing).setStroke()
        ring.stroke()

        // The dot. It pulses while recording and brightens on hover.
        var dotInset = outer.width * 0.26
        if isRecording {
            dotInset += CGFloat(sin(pulsePhase) * 1.2)
        }
        let dot = NSBezierPath(ovalIn: outer.insetBy(dx: dotInset, dy: dotInset))

        let colour: NSColor
        if !isEnabled {
            colour = Theme.Color.recordDisabled
        } else if isRecording {
            colour = Theme.Color.recordActive
        } else {
            colour = isHovering ? Theme.Color.recordHover : Theme.Color.recordIdle
        }

        NSGraphicsContext.saveGraphicsState()
        if isRecording {
            // A glow, so it is obvious across a dark room that this is running.
            let glow = NSShadow()
            glow.shadowColor = Theme.Color.recordActive.withAlphaComponent(0.8)
            glow.shadowBlurRadius = 6
            glow.shadowOffset = .zero
            glow.set()
        }
        colour.setFill()
        dot.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    private func startPulsing() {
        pulseTimer?.invalidate()
        // Slow enough to read as a pulse rather than a flicker.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase += 0.35
            self.needsDisplay = true
        }
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = 0
    }
}
