//
//  VBBusButton.swift — a hardware switcher's bus button.
//
//  Purpose : The cut was a standard push button reading "CUT TO TWO". It worked and
//            it looked like a web form: a small rounded rectangle among other small
//            rounded rectangles, giving no sign that it is the most consequential
//            control in the window. Hardwired switchers solved this decades ago —
//            big square buttons, one per source, lit when that source is on air. You
//            hit them without looking, and the lit one tells you what is going out.
//  Inputs  : a label, a bus tint, and how much of the picture this source is.
//  Outputs : a click, and a tally lamp.
//  Connects: FaderPanelBody, Theme.
//  Extend  : more sources on a bus is more buttons in the row. Do NOT add text to
//            them — the label is one or two characters on purpose, because that is
//            what makes the button big enough to hit and the row readable at a
//            glance.
//
//  On the colour: red means on air, everywhere in broadcast, and it is not used for
//  anything else in this window. Partly on air is the bus's own tint rather than a
//  dimmer red, because a half-lit tally lamp is ambiguous and a tinted one is not.
//

import AppKit

/// A big, square, lit-when-live source button.
final class VBBusButton: NSControl {

    /// One or two characters. Longer than that and it stops being a button you can
    /// hit without reading.
    let label: String

    /// This source's identity colour, shown while it is partly on air.
    var busTint: NSColor = Theme.Color.accent {
        didSet { needsDisplay = true }
    }

    /// How much of the picture this source currently is, 0...1.
    ///
    /// Not a boolean: a crossfader spends most of its life between the two ends, and
    /// a lamp that is either on or off would be lying for all of it.
    var onAirAmount: Double = 0 {
        didSet {
            guard abs(onAirAmount - oldValue) > 0.005 else { return }
            needsDisplay = true
        }
    }

    /// Every bus key beneath a view, for the self-QA render.
    static func all(in view: NSView) -> [VBBusButton] {
        var found: [VBBusButton] = []
        if let key = view as? VBBusButton { found.append(key) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(label: String, busTint: NSColor) {
        self.label = label
        self.busTint = busTint
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Cut to \(label)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.BusButton.width, height: Theme.BusButton.height)
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

        // Track to the mouse-up so a press that slides off the button is cancelled,
        // the way a physical button you roll off the edge of does not fire.
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
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.BusButton.cornerRadius, yRadius: Theme.BusButton.cornerRadius)

        // The lamp. Full red on air, the bus tint on the way there, unlit metal when
        // this source is not contributing at all.
        let lamp: NSColor
        if onAirAmount >= 0.995 {
            lamp = Theme.Color.tallyOnAir
        } else if onAirAmount > 0.005 {
            lamp = busTint.blended(
                withFraction: onAirAmount * 0.5, of: Theme.Color.tallyOnAir) ?? busTint
        } else {
            lamp = Theme.Color.busButtonUnlit
        }

        var fill = lamp
        if onAirAmount <= 0.005 {
            // Unlit buttons still have to look pressable, so hover and press move
            // them rather than leaving them dead.
            if isPressed {
                fill = lamp.blended(withFraction: 0.35, of: .black) ?? lamp
            } else if isHovering {
                fill = lamp.blended(withFraction: 0.18, of: .white) ?? lamp
            }
        } else if isPressed {
            fill = lamp.blended(withFraction: 0.25, of: .black) ?? lamp
        }
        fill.setFill()
        path.fill()

        // A lip along the top, which is what makes it read as a key with a height to
        // it rather than a coloured rectangle.
        let lip = NSBezierPath(
            roundedRect: NSRect(
                x: body.minX, y: body.maxY - Theme.BusButton.lipHeight,
                width: body.width, height: Theme.BusButton.lipHeight),
            xRadius: Theme.BusButton.cornerRadius, yRadius: Theme.BusButton.cornerRadius)
        NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.14).setFill()
        lip.fill()

        Theme.Color.panelBorder.setStroke()
        path.lineWidth = Theme.Metrics.hairline
        path.stroke()

        // The letter, as large as the box will carry — and never larger. A label
        // that overflows draws outside the key and onto its neighbour, which is what
        // "ONE" did before these became numbers.
        let onAir = onAirAmount > 0.4
        let colour = onAir
            ? NSColor.white
            : Theme.Color.textPrimary.withAlphaComponent(isHovering ? 1.0 : 0.75)
        let text = label as NSString
        var font = Theme.Font.busButton
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        var size = text.size(withAttributes: attributes)
        let available = body.width - 6
        if size.width > available, size.width > 0 {
            let scaled = max(font.pointSize * available / size.width, 8)
            font = NSFont.systemFont(ofSize: scaled, weight: .bold)
            attributes[.font] = font
            size = text.size(withAttributes: attributes)
        }
        text.draw(
            at: NSPoint(
                x: body.midX - size.width / 2,
                y: body.midY - size.height / 2 - Theme.BusButton.lipHeight / 2),
            withAttributes: attributes)
    }
}
