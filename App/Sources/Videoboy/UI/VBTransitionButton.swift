//
//  VBTransitionButton.swift — the crossfader's transition pattern, as a pictogram key.
//
//  Purpose : The left-hand partner of VBBlendButton. BLEND (right of the transport
//            cluster) says how the two layers combine; this (left of it) says what
//            SHAPE the move takes — dissolve, wipe, slide, push, iris, split,
//            interlace. Click it and the patterns pop out under the pointer.
//  Inputs  : a click, and the current transition.
//  Outputs : `onTransitionChosen`, and `onAVE5PanelRequested` — with AVE-5 armed a
//            click opens the AVE-5 wipe block instead of the menu (the block's
//            "Transitions…" button, `showMenu`, is the way back out).
//  Connects: FaderPanelBody, Transition (whose menu grouping this shows).
//  Extend  : a new pattern needs a case in `drawPictogram` — the switch is
//            exhaustive, so the compiler will say so.
//
//  ── WHY THIS ONE DRAWS EVERY PATTERN WHEN THE BLEND ICON DOES NOT ─────────────
//
//  VBBlendButton deliberately draws one icon for all fourteen modes: "multiply" has
//  no shape. A wipe IS a shape, and the pattern-select keys on an MX-1 were
//  pictograms for exactly that reason — you read the key, not a label. So the key
//  shows the armed pattern, and the menu shows every pattern the same way.
//
//  The pictograms show the move half-way: the filled area is where the incoming
//  source has arrived at the fader's midpoint, on the same left-to-right and
//  top-to-bottom directions the shader uses.
//

import AppKit
import VideoboyCore

/// A square key showing the armed transition, which pops out the pattern menu.
final class VBTransitionButton: NSControl, AuditableControl {

    /// Driven by `onTransitionChosen`, not target/action, so it answers the audit itself.
    var isWiredForAudit: Bool { onTransitionChosen != nil }

    /// The pattern currently armed, drawn on the key and ticked in the menu.
    var transition: Transition = .dissolve {
        didSet {
            guard transition != oldValue else { return }
            updateTooltip()
            needsDisplay = true
        }
    }

    /// Called when a pattern is chosen from the menu.
    var onTransitionChosen: ((Transition) -> Void)?

    /// The AVE-5 wipe block's state, drawn on the key when AVE-5 is armed — the
    /// pattern the keys add up to, so the key says which wipe is lit.
    var ave5 = AVE5Wipe() {
        didSet {
            guard ave5 != oldValue, transition == .ave5 else { return }
            updateTooltip()
            needsDisplay = true
        }
    }

    /// Called, with this key as the anchor, when AVE-5 is armed and the key is
    /// clicked — or just chosen from the menu.
    var onAVE5PanelRequested: ((NSView) -> Void)?

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

    /// Side of the pictograms drawn into the menu, in points.
    private static let menuImageSide: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateTooltip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Square, and the same height as the transport keys beside it — the same
    /// footprint as the blend key it mirrors.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.BusButton.height, height: Theme.BusButton.height)
    }

    private func updateTooltip() {
        if transition == .ave5 {
            toolTip = "Transition: AVE-5 (\(ave5.shape.displayName)). Click for the wipe "
                + "block — pattern keys, MULTI, ONE-WAY, REVERSE and the positioner."
            return
        }
        toolTip = "Transition: \(transition.displayName). The shape the move takes "
            + "as the fader travels — FADE, CUT, sweeps and MIDI all follow it."
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
        if transition == .ave5, let onAVE5PanelRequested {
            onAVE5PanelRequested(self)
        } else {
            popOutMenu(at: convert(event.locationInWindow, from: nil))
        }
        isPressed = false
    }

    /// Pops the pattern menu out below the key — the AVE-5 block's way back to the
    /// other transitions, since with AVE-5 armed a click opens the block instead.
    func showMenu() {
        popOutMenu(at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    /// The pattern menu, grouped by family, each item carrying its pictogram.
    /// Built separately from `popOutMenu` so a check can inspect it without a click.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, group) in Transition.menuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for pattern in group {
                let item = NSMenuItem(
                    title: pattern.displayName,
                    action: #selector(transitionPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pattern.rawValue
                item.state = pattern == transition ? .on : .off
                item.image = Self.menuImage(for: pattern)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Pops the menu out at the pointer, as VBBlendButton does and for the same
    /// reason: the first item is then the same short distance away wherever you
    /// clicked on a small key.
    private func popOutMenu(at point: NSPoint) {
        makeMenu().popUp(positioning: nil, at: point, in: self)
    }

    /// Chooses a pattern as if it had been picked from the menu. Used by the menu
    /// and by self-QA, so the check exercises the same path a click does.
    func choose(_ pattern: Transition) {
        transition = pattern
        onTransitionChosen?(pattern)
        sendAction(action, to: target)
        // Choosing AVE-5 from the menu opens its block straight away: the block is
        // where the pattern is actually chosen.
        if pattern == .ave5 { onAVE5PanelRequested?(self) }
    }

    @objc private func transitionPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let picked = Transition(rawValue: raw) else { return }
        choose(picked)
    }

    /// A template image of a pattern's pictogram, for a menu item.
    private static func menuImage(for pattern: Transition) -> NSImage {
        let side = menuImageSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let body = rect.insetBy(dx: 1, dy: 1)
            let frame = NSBezierPath(rect: body)
            NSColor.black.setStroke()
            frame.lineWidth = 1
            frame.stroke()
            NSGraphicsContext.saveGraphicsState()
            frame.addClip()
            drawPictogram(pattern, in: body, ink: .black)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        // Same guard as VBBlendButton: a view asked to draw before layout gets a
        // null rect from `insetBy`, and path-building on that throws.
        let body = bounds.insetBy(dx: 1.5, dy: 1.5)
        guard body.width > 1, body.height > 1, !body.isNull, !body.isInfinite else { return }
        let radius = Theme.OptionButton.cornerRadius
        let frame = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

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
        Self.drawPictogram(transition, in: body, ink: ink, ave5: ave5)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws a pattern half-way through its move: filled is where the incoming
    /// source has arrived. AppKit's y axis points UP, so "the top" is `maxY`.
    static func drawPictogram(
        _ pattern: Transition, in body: NSRect, ink: NSColor, ave5: AVE5Wipe = AVE5Wipe()
    ) {
        ink.setFill()
        let midX = body.midX
        let midY = body.midY
        switch pattern {
        case .dissolve:
            // A ramp from solid to nothing: the whole picture, changing gradually.
            // A flat half-tone read as an empty or disabled key, and this is the
            // pattern the key shows by default.
            NSGradient(starting: ink, ending: ink.withAlphaComponent(0))?
                .draw(in: body, angle: 0)
        case .wipeHorizontal:
            NSRect(x: body.minX, y: body.minY, width: body.width / 2, height: body.height).fill()
        case .wipeVertical:
            NSRect(x: body.minX, y: midY, width: body.width, height: body.height / 2).fill()
        case .slideHorizontal, .pushHorizontal:
            let arrived = NSRect(x: body.minX, y: body.minY, width: body.width / 2, height: body.height)
            arrived.fill()
            // A chevron cut out of the arrived half says it MOVED in; a push has a
            // second chevron in the other half, because that picture moves too.
            chevron(pointing: .right, centre: NSPoint(x: arrived.midX, y: midY),
                    size: body.height * 0.35, colour: knockout)
            if pattern == .pushHorizontal {
                chevron(pointing: .right, centre: NSPoint(x: midX + body.width / 4, y: midY),
                        size: body.height * 0.35, colour: ink)
            }
        case .slideVertical, .pushVertical:
            let arrived = NSRect(x: body.minX, y: midY, width: body.width, height: body.height / 2)
            arrived.fill()
            chevron(pointing: .down, centre: NSPoint(x: midX, y: arrived.midY),
                    size: body.width * 0.35, colour: knockout)
            if pattern == .pushVertical {
                chevron(pointing: .down, centre: NSPoint(x: midX, y: midY - body.height / 4),
                        size: body.width * 0.35, colour: ink)
            }
        case .iris:
            let diameter = min(body.width, body.height) * 0.62
            NSBezierPath(ovalIn: NSRect(
                x: midX - diameter / 2, y: midY - diameter / 2,
                width: diameter, height: diameter)).fill()
        case .splitHorizontal:
            NSRect(x: midX - body.width / 4, y: body.minY,
                   width: body.width / 2, height: body.height).fill()
        case .splitVertical:
            NSRect(x: body.minX, y: midY - body.height / 4,
                   width: body.width, height: body.height / 2).fill()
        case .interlaceHorizontal, .interlaceVertical:
            // A comb: strips alternating which end the fill has come from.
            let strips = 6
            let horizontal = pattern == .interlaceHorizontal
            let stripSize = (horizontal ? body.height : body.width) / CGFloat(strips)
            for strip in 0..<strips {
                let fromStart = strip % 2 == 0
                if horizontal {
                    // Strip 0 is the TOP line, so count down from maxY.
                    let y = body.maxY - CGFloat(strip + 1) * stripSize
                    let x = fromStart ? body.minX : midX
                    NSRect(x: x, y: y, width: body.width / 2, height: stripSize).fill()
                } else {
                    let x = body.minX + CGFloat(strip) * stripSize
                    let y = fromStart ? midY : body.minY
                    NSRect(x: x, y: y, width: stripSize, height: body.height / 2).fill()
                }
            }
        case .ave5:
            drawAVE5Pictogram(ave5, in: body, ink: ink)
        }
    }

    /// Cells across the AVE-5 pictogram. Coarse on purpose: a 4:3 grid this size
    /// reads every pattern in the table, ×16 included, and it is redrawn only when
    /// the block changes.
    private static let ave5Columns = 24
    private static let ave5Rows = 18

    /// The block's pattern part-way through the move, sampled from the same field
    /// the shader draws (`AVE5Wipe.arrives`), so the key cannot show a different
    /// shape from the picture. 40% rather than half-way so a cut — which switches
    /// AT half-way — shows as not yet taken rather than as a full key.
    private static func drawAVE5Pictogram(_ block: AVE5Wipe, in body: NSRect, ink: NSColor) {
        if block.keys.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: ink
            ]
            let label = "CUT" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
                       withAttributes: attributes)
            return
        }
        let cellWidth = body.width / CGFloat(ave5Columns)
        let cellHeight = body.height / CGFloat(ave5Rows)
        for row in 0..<ave5Rows {
            for column in 0..<ave5Columns {
                let u = (Double(column) + 0.5) / Double(ave5Columns)
                let v = (Double(row) + 0.5) / Double(ave5Rows)
                guard block.arrives(u: u, v: v, progress: 0.4, aspect: 4.0 / 3.0,
                                    reversed: block.reverse,
                                    pixel: (Double(column), Double(row))) else { continue }
                // Row 0 is the TOP of the picture; AppKit's y points up.
                NSRect(x: body.minX + CGFloat(column) * cellWidth,
                       y: body.maxY - CGFloat(row + 1) * cellHeight,
                       width: cellWidth + 0.5, height: cellHeight + 0.5).fill()
            }
        }
    }

    /// The colour of a shape cut out of a filled area — the picture's background,
    /// as VBBlendButton's knocked-out letter explains.
    private static let knockout = NSColor(white: 0.08, alpha: 1)

    private enum ChevronDirection { case right, down }

    /// A small open arrowhead, stroked.
    private static func chevron(
        pointing direction: ChevronDirection, centre: NSPoint, size: CGFloat, colour: NSColor
    ) {
        let half = size / 2
        let path = NSBezierPath()
        switch direction {
        case .right:
            path.move(to: NSPoint(x: centre.x - half / 2, y: centre.y + half))
            path.line(to: NSPoint(x: centre.x + half / 2, y: centre.y))
            path.line(to: NSPoint(x: centre.x - half / 2, y: centre.y - half))
        case .down:
            path.move(to: NSPoint(x: centre.x - half, y: centre.y + half / 2))
            path.line(to: NSPoint(x: centre.x, y: centre.y - half / 2))
            path.line(to: NSPoint(x: centre.x + half, y: centre.y + half / 2))
        }
        colour.setStroke()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
