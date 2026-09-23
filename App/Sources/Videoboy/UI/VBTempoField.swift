//
//  VBTempoField.swift — the BPM readout, which is also how you set it.
//
//  Purpose : Tap it to set the tempo by feel; drag it to set the tempo by number. The
//            readout was a label with a separate TAP key beside it, which is two
//            controls for one value and a key that does nothing at any other moment.
//  Inputs  : clicks and vertical drags.
//  Outputs : `onTap` per click, `onTempoDragged` with a new BPM.
//  Connects: TransportDisplayView, which owns the tempo and the beat.
//  Extend  : anything else that sets tempo belongs here too, for the same reason TAP
//            moved in — a value should have one place you touch to change it.
//
//  ── WHY BOTH GESTURES ON ONE CONTROL ────────────────────────────────────────────
//
//  They answer different questions. Tapping answers "match THIS", which is what you do
//  against a record playing in the room, and it needs no precision because the taps
//  carry it. Dragging answers "make it exactly 128", which is what you do when you know
//  the number. Neither replaces the other, and both are about the same value, so both
//  live on the thing showing that value.
//
//  A click is a tap and a drag is a scrub, distinguished by whether the pointer moves.
//  That is the same rule a DJ mixer's jog wheel uses, and it means neither gesture
//  needs to be learned.
//

import AppKit
import VideoboyCore

/// The tempo readout: tap to set by feel, drag to set by number.
final class VBTempoField: NSControl {

    /// Called once per tap, for the tap-tempo averager.
    var onTap: (() -> Void)?
    /// Called while dragging, with the new tempo.
    var onTempoDragged: ((Double) -> Void)?

    /// The tempo shown.
    var beatsPerMinute: Double = 120 {
        didSet {
            guard abs(beatsPerMinute - oldValue) > 0.049 else { return }
            label.stringValue = String(format: "%.1f", beatsPerMinute)
        }
    }

    /// How far through the current beat the transport is, 0...1.
    ///
    /// Drives a very quiet pulse behind the number. Subtle on purpose: it is a thing
    /// you notice when you look for it and never while you are reading the number,
    /// which is the difference between a heartbeat and a strobe.
    var beatPhase: Double = 0 {
        didSet { needsDisplay = true }
    }

    /// Whether the transport is actually running, so a stopped clock does not pulse.
    var isRunning = false { didSet { needsDisplay = true } }

    private let label = NSTextField(labelWithString: "120.0")
    private let unit = NSTextField(labelWithString: "BPM")
    private var isFlashing = false
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3

        label.font = Theme.Font.osd(size: 20, weight: .medium)
        label.textColor = Theme.Color.displayText
        label.isSelectable = false
        unit.font = Theme.Font.osd(size: 10)
        unit.textColor = Theme.Color.displayDimText
        unit.isSelectable = false

        let row = Controls.row([label, unit], spacing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        toolTip = "Tap to set the tempo by ear. Drag up and down to set it exactly — "
            + "hold Shift while dragging for tenths."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    // MARK: - Tap and drag

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let startTempo = beatsPerMinute
        var moved = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }

            let point = convert(next.locationInWindow, from: nil)
            let travel = point.y - start.y
            // Below this it is a click that wobbled, not a drag. Without the slop a
            // tap on a trackpad often registers as a one-pixel drag and changes the
            // tempo instead of tapping it.
            guard moved || abs(travel) > 2 else { continue }
            moved = true

            // A tenth of a BPM per point with Shift, one per four points without.
            // Four rather than one because a 200-point drag should cross the useful
            // range once, not fifty times.
            let perPoint = next.modifierFlags.contains(.shift) ? 0.1 : 0.25
            let tempo = min(max(startTempo + travel * perPoint, 20), 300)
            beatsPerMinute = tempo
            onTempoDragged?(tempo)
        }

        // No movement means it was a tap.
        guard !moved else { return }
        flash()
        onTap?()
    }

    /// A brief light, so a tap that lands is acknowledged.
    ///
    /// It has to be: the tempo does not move until the fourth tap, so without this the
    /// first three taps produce no feedback at all and feel ignored. Beat detection
    /// uses a longer one when it locks onto a new tempo, so a number that changed on
    /// its own is seen to have changed.
    func flash(duration: TimeInterval = 0.09) {
        isFlashing = true
        needsDisplay = true
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            // A newer flash owns the light; let it end it.
            guard let self, self.flashGeneration == generation else { return }
            self.isFlashing = false
            self.needsDisplay = true
        }
    }

    /// Which flash is current, so an early one does not cut a later one short.
    private var flashGeneration = 0

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 2, bounds.height > 2 else { return }
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)

        // The beat pulse. Decays across the beat rather than blinking on and off, so
        // it reads as a pulse rather than as something flickering.
        if isRunning {
            let decay = pow(1 - min(max(beatPhase, 0), 1), 2.2)
            NSColor.white.withAlphaComponent(0.05 * decay).setFill()
            path.fill()
        }

        if isFlashing {
            Theme.Color.accent.withAlphaComponent(0.35).setFill()
            path.fill()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.06).setFill()
            path.fill()
        }

        if isHovering {
            Theme.Color.displayDimText.withAlphaComponent(0.5).setStroke()
            path.lineWidth = Theme.Metrics.hairline
            path.stroke()
        }
    }
}
