//
//  VBStepButton.swift — the shuttle's step-rate key, on a DJ deck's rules.
//
//  Purpose : Step playback was a popup listing seven presets. A popup is the wrong
//            shape for this: the rates are a LADDER, you move along it by feel while
//            watching the picture, and opening a menu to do that takes your eyes off
//            the thing you are timing against. Numark's decks solve it with one key —
//            it reads STEP when off, clicking walks toward faster, control-clicking
//            walks toward slower.
//  Inputs  : clicks and control-clicks.
//  Outputs : a `PlaybackTiming`.
//  Connects: SourcePanelBody, PlaybackTiming's two ladders.
//  Extend  : a new rung is an entry in `PlaybackTiming.slowLadder` or `fastLadder`.
//            Do not add a rung to both — the two halves must stay disjoint or a click
//            and a control-click can land on the same rate and the ladder stalls.
//
//  Position is held as a signed index with zero meaning "off": positive walks the
//  fast ladder, negative the slow one. That is what makes one key do both directions
//  without a mode, and what makes "back the way you came" work from either side.
//

import AppKit
import VideoboyCore

/// One key that walks the step-rate ladder in both directions.
final class VBStepButton: NSControl, AuditableControl {

    /// Called whenever the rate changes.
    var onTimingChanged: ((PlaybackTiming) -> Void)?

    /// Driven by a closure rather than target/action, so it answers for itself.
    var isWiredForAudit: Bool { onTimingChanged != nil }

    /// Zero is off. Positive indexes the fast ladder, negative the slow one.
    private var position = 0

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    /// The timing this key currently represents.
    var timing: PlaybackTiming {
        if position > 0 {
            let ladder = PlaybackTiming.fastLadder
            return ladder[min(position - 1, ladder.count - 1)]
        }
        if position < 0 {
            let ladder = PlaybackTiming.slowLadder
            return ladder[min(-position - 1, ladder.count - 1)]
        }
        return .continuous
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Step rate. Click for faster, Control-click for slower, "
            + "and it returns to STEP at either end."
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

    /// Walks the ladder. From off, the direction chooses which half to walk into;
    /// from a rung, it walks back toward off and out the other side.
    private func step(by direction: Int) {
        let fastCount = PlaybackTiming.fastLadder.count
        let slowCount = PlaybackTiming.slowLadder.count

        var next = position + direction
        if next > fastCount { next = 0 }
        if next < -slowCount { next = 0 }
        position = next

        needsDisplay = true
        Log.info(.app, "step rate is now \(timing.displayName)")
        onTimingChanged?(timing)
    }

    /// Sets the key without firing its callback, for restoring saved state.
    func setTiming(_ timing: PlaybackTiming) {
        if case .continuous = timing {
            position = 0
        } else if let index = PlaybackTiming.fastLadder.firstIndex(of: timing) {
            position = index + 1
        } else if let index = PlaybackTiming.slowLadder.firstIndex(of: timing) {
            position = -(index + 1)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.OptionButton.cornerRadius,
            yRadius: Theme.OptionButton.cornerRadius)

        // Lit whenever stepping is ON, so a glance says whether this clip is running
        // or holding — which is the question, not what the rate happens to be.
        let isStepping = position != 0
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
