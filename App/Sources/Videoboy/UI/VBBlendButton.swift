//
//  VBBlendButton.swift — the blend mode, as an icon that pops out its menu.
//
//  Purpose : BLEND was a popup wide enough to show "Color Dodge", which meant it was
//            wide enough to shove the transport keys off centre and still truncate to
//            "No…". The mode matters; the WORD does not need to be on screen at all
//            times. This is a square icon that pops the menu out on click.
//  Inputs  : a click, and the current mode.
//  Outputs : `onModeChosen`.
//  Connects: FaderPanelBody, BlendMode (whose menu grouping this shows).
//  Extend  : the icon says "two layers combining", not which mode. Do not try to draw
//            thirteen different icons — the tooltip and the menu tick say which, and a
//            set of thirteen abstract glyphs is thirteen things to learn.
//
//  ── THE ICON ────────────────────────────────────────────────────────────────────
//
//  A square split by a diagonal. The left half is filled with an A KNOCKED OUT of it;
//  the right half is the negative of that, a solid B on the opposite tone. It is the
//  same idea as Photoshop's layer-blend thumbnails and as the A/B on a vision mixer:
//  two things, meeting along a line, each one the inverse of the other. The slash is
//  the join, which is exactly what a blend mode governs.
//

import AppKit
import VideoboyCore

/// A compact two-layer icon that pops out the blend menu.
final class VBBlendButton: NSControl, AuditableControl {

    /// Driven by `onModeChosen`, not target/action, so it answers the audit itself.
    var isWiredForAudit: Bool { onModeChosen != nil }


    /// The two layers this bus combines, as the bus's own letters.
    ///
    /// A/B on the A/B fader, C/D on C/D, 1/2 on Program. It was hard-coded to "A" and
    /// "B", which on the C/D panel named two layers that are not there — an icon that
    /// says the wrong thing is worse than one that says nothing.
    var lowerLabel = "A"
    var upperLabel = "B"

    /// The mode currently chosen, for the tick in the menu and the tooltip.
    var mode: BlendMode = .normal {
        didSet {
            guard mode != oldValue else { return }
            updateTooltip()
            needsDisplay = true
        }
    }

    /// Called when a mode is chosen from the menu.
    var onModeChosen: ((BlendMode) -> Void)?

    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
        }
    }
    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateTooltip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Square, and the same height as the transport keys beside it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.BusButton.height, height: Theme.BusButton.height)
    }

    private func updateTooltip() {
        toolTip = "Blend: \(mode.displayName). How \(lowerLabel) and \(upperLabel) "
            + "combine — the fader below sets how much of each."
    }

    /// Names the two layers, and redraws.
    func setLabels(lower: String, upper: String) {
        lowerLabel = lower
        upperLabel = upper
        updateTooltip()
        needsDisplay = true
    }

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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        popOutMenu(at: convert(event.locationInWindow, from: nil))
        isPressed = false
    }

    /// Pops the grouped menu out beside the button.
    ///
    /// Popped rather than shown as a popup button's own list so the button can stay
    /// square: an NSPopUpButton is as wide as its widest title whether or not you want
    /// it to be, which is the problem this control exists to solve.
    private func popOutMenu(at point: NSPoint) {
        let menu = NSMenu()
        for (index, group) in BlendMode.menuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for blend in group {
                let item = NSMenuItem(
                    title: blend.displayName,
                    action: #selector(modePicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = blend.rawValue
                item.state = blend == mode ? .on : .off
                menu.addItem(item)
            }
        }
        // AT THE POINTER, not at a corner of the button. A menu that opens from a
        // fixed point means the first item is a different distance away depending on
        // where you happened to click, and on a control this small that is most of the
        // travel. Opening under the cursor puts the list where the hand already is.
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func modePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let picked = BlendMode(rawValue: raw) else { return }
        mode = picked
        onModeChosen?(picked)
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A view can be asked to draw before it has been laid out. `insetBy` on a
        // zero-sized rect returns CGRect.null, whose minX is INFINITY — and
        // `move(to:)` with an infinite point is silently ignored, so the `line(to:)`
        // after it throws "No current point for line" and takes the app with it.
        //
        // Found by the self-QA UI check, which builds the window at three widths and
        // therefore hits exactly this. Guarding the rect is the fix; a view with no
        // room simply draws nothing.
        let body = bounds.insetBy(dx: 1.5, dy: 1.5)
        guard body.width > 1, body.height > 1, !body.isNull, !body.isInfinite else { return }
        let radius = Theme.OptionButton.cornerRadius
        let frame = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        // The A side: filled, with the letter knocked out of it.
        let ink = isEnabled
            ? (isHovering ? Theme.Color.textPrimary : Theme.Color.textSecondary)
            : Theme.Color.textTertiary.withAlphaComponent(0.5)

        if isPressed || isHovering {
            NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.08).setFill()
            frame.fill()
        }
        ink.setStroke()
        frame.lineWidth = Theme.Metrics.hairline
        frame.stroke()

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()

        // The diagonal. Everything left of it is the A side, everything right the B.
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: body.minX, y: body.minY))
        slash.line(to: NSPoint(x: body.maxX, y: body.maxY))

        let aSide = NSBezierPath()
        aSide.move(to: NSPoint(x: body.minX, y: body.minY))
        aSide.line(to: NSPoint(x: body.maxX, y: body.maxY))
        aSide.line(to: NSPoint(x: body.minX, y: body.maxY))
        aSide.close()
        ink.setFill()
        aSide.fill()

        // The letters. A is knocked OUT of the filled half — drawn in the background
        // colour — and B is drawn in ink on the empty half. Each is the negative of
        // the other, which is the whole idea.
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        func letter(_ text: String, colour: NSColor, at point: NSPoint) {
            let string = text as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: colour
            ]
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                withAttributes: attributes)
        }
        // Knocked out in near-black rather than in the panel fill. The panel fill is a
        // 4.5% white over a dark canvas — against an ink-filled half it is very nearly
        // the same tone, so the first letter was invisible. A cutout has to be the
        // BACKGROUND of the picture, not the background of the panel.
        letter(lowerLabel, colour: NSColor(white: 0.08, alpha: 1),
               at: NSPoint(x: body.minX + body.width * 0.30, y: body.minY + body.height * 0.70))
        letter(upperLabel, colour: ink,
               at: NSPoint(x: body.minX + body.width * 0.70, y: body.minY + body.height * 0.30))

        // The join, drawn last so it reads as a hard edge between the two halves
        // rather than as the boundary of a shape. Same near-black as the cutout, so
        // the slash and the knocked-out letter read as the same "absence".
        NSColor(white: 0.08, alpha: 1).setStroke()
        slash.lineWidth = 1.5
        slash.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }
}
