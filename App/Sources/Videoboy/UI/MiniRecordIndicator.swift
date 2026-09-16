//
//  MiniRecordIndicator.swift — the per-preview arm/record dot.
//
//  Purpose : Each preview carries its own record control, so arming a channel is done
//            where you are already looking at it rather than in a separate dialogue.
//            Armed indicators pulse on the musical clock, which is how you can tell
//            at a glance that several are armed and running together.
//  Inputs  : `isArmed`, and a musical phase pushed in each frame.
//  Outputs : target/action on click.
//  Connects: MetalPreviewView hosts one; ShellController drives the phase from the
//            transport and collects the armed set for the recorder.
//
//  The pulse is at HALF the tempo — one every two beats. At a beat it reads as a
//  flicker and competes with the picture behind it; at two beats it is unmistakably
//  deliberate and still clearly locked to the music.
//

import AppKit
import VideoboyCore

/// A small record dot sitting over a preview.
final class MiniRecordIndicator: NSControl {

    /// Channel label shown beside the dot: A, B, C, D, 1, 2, P.
    let label: String

    /// Whether this feed is armed for recording.
    var isArmed = false {
        didSet { needsDisplay = true }
    }

    /// Whether recording is actually running. Armed-and-running is what pulses.
    var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// Position within the pulse, 0..<1, pushed in from the transport.
    var pulsePhase: Double = 0 {
        didSet {
            // Only an armed indicator animates, so an idle window costs nothing.
            if isArmed { needsDisplay = true }
        }
    }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Arm \(label) for recording"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.Record.miniWidth, height: Theme.Record.miniHeight)
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
        // A dark plate behind the dot and letter, so both stay readable over any
        // picture — a bare dot disappears over bright video.
        let plate = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(isHovering ? 0.72 : 0.5).setFill()
        plate.fill()

        let dotDiameter = Theme.Record.miniDotDiameter
        let dotRect = NSRect(
            x: 3,
            y: (bounds.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )

        let dotColour: NSColor
        if isArmed {
            // The fade: bright at the top of the pulse, easing down across the two
            // beats. Squaring the falloff makes the decay read as graceful rather
            // than linear, which looks mechanical.
            let falloff = pow(1.0 - pulsePhase, 2.0)
            let brightness = Theme.Record.miniPulseFloor
                + (1.0 - Theme.Record.miniPulseFloor) * falloff
            dotColour = Theme.Color.recordActive.withAlphaComponent(
                isRecording ? CGFloat(brightness) : CGFloat(brightness) * 0.75)
        } else {
            dotColour = isHovering ? Theme.Color.recordIdle : Theme.Color.recordDisarmed
        }

        NSGraphicsContext.saveGraphicsState()
        if isArmed && isRecording {
            let glow = NSShadow()
            glow.shadowColor = Theme.Color.recordActive.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 4
            glow.shadowOffset = .zero
            glow.set()
        }
        dotColour.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        // An unarmed dot gets a ring so it still reads as a control rather than as a
        // smudge on the picture.
        if !isArmed {
            Theme.Color.recordRing.setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.tinyLabel,
            .foregroundColor: isArmed ? Theme.Color.textPrimary : Theme.Color.textSecondary
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: dotRect.maxX + 3, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        isArmed.toggle()
        Log.info(.app, "record \(isArmed ? "armed" : "disarmed") for \(label)")
        sendAction(action, to: target)
    }
}
