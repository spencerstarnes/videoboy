//
//  VBTransportButton.swift — the round transport keys.
//
//  Purpose : Play was a standard small push button sitting between a segmented
//            control and a readout, which gave it none of the weight of the thing it
//            does. Record already had a proper key; this gives play the same one, so
//            the two controls that start and stop everything look like each other and
//            like nothing else in the window.
//  Inputs  : a glyph and a colour for the lit state.
//  Outputs : a click.
//  Connects: TransportToolbarView, TransportDisplayView (which carries Tap).
//  Extend  : another transport key is another instance with another glyph. Keep them
//            the same size — a row of round keys reads as a transport, and one that
//            is a different size reads as a mistake.
//

import AppKit

/// A round, chunky transport key.
final class VBTransportButton: NSControl {

    /// What is drawn in the middle. One glyph, because that is what fits.
    var glyph: String {
        didSet { needsDisplay = true }
    }

    /// True when the thing this key controls is currently happening.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The colour of the lit state.
    var activeColour: NSColor = Theme.Color.accent

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(glyph: String, activeColour: NSColor = Theme.Color.accent) {
        self.glyph = glyph
        self.activeColour = activeColour
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Wider than it is tall when the glyph is a word rather than a symbol.
    override var intrinsicContentSize: NSSize {
        let diameter = Theme.Record.buttonDiameter
        return glyph.count > 1
            ? NSSize(width: diameter * 1.45, height: diameter)
            : NSSize(width: diameter, height: diameter)
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
        isPressed = true
        needsDisplay = true

        // Track to the mouse-up, so sliding off the key cancels it the way a physical
        // button you roll off the edge of does not fire.
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
        needsDisplay = true
        if fired { sendAction(action, to: target) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 1, dy: 1)
        let radius = body.height / 2
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        var fill = isActive ? activeColour : Theme.Color.busButtonUnlit
        if isPressed {
            fill = fill.blended(withFraction: 0.3, of: .black) ?? fill
        } else if isHovering {
            fill = fill.blended(withFraction: 0.16, of: .white) ?? fill
        }
        fill.setFill()
        path.fill()

        // The same lip the bus keys have, so the transport reads as the same kit.
        NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.12).setFill()
        NSBezierPath(roundedRect: NSRect(
            x: body.minX + 2, y: body.midY,
            width: body.width - 4, height: body.height / 2 - 2),
            xRadius: radius / 2, yRadius: radius / 2).fill()

        Theme.Color.panelBorder.setStroke()
        path.lineWidth = Theme.Metrics.hairline
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: glyph.count > 1
                ? Theme.Font.osd(size: 11)
                : NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: isActive || isHovering
                ? NSColor.white : Theme.Color.textPrimary.withAlphaComponent(0.8)
        ]
        let text = glyph as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes)
    }
}
