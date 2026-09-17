//
//  CollapseStripView.swift — the gap in an effect header, made to do something.
//
//  Purpose : Every effect card has dead space between its name and its enable switch,
//            put there to push the switch to the right. It is the largest quiet target
//            on the card and it did nothing. Clicking it now folds the effect down to
//            its header.
//  Inputs  : clicks, and hover.
//  Outputs : `onClick`.
//  Connects: EffectChainPanelBody, which owns the collapsed state and hides the rows.
//  Extend  : this reports a click and draws a hint. It must not know what collapsing
//            means — the panel decides that, and keeps the state.
//
//  ── WHY A CHEVRON THAT IS USUALLY INVISIBLE ─────────────────────────────────────
//
//  A permanent chevron would be a new control in a layout that is fixed, repeated down
//  a column already dense with switches and badges. But a click target with no hint at
//  all is one nobody finds.
//
//  So it appears ON HOVER — the pointer is already the thing asking the question — and
//  STAYS VISIBLE WHILE COLLAPSED, pointing right. That second case is the one that
//  matters: a folded card with no marking looks exactly like an effect that happens to
//  have no parameters, and the difference has to be legible at a glance.
//

import AppKit

/// The clickable gap in an effect's header row.
final class CollapseStripView: NSView {

    /// Called when the strip is clicked.
    var onClick: (() -> Void)?

    /// Which way the chevron points, and whether it stays on when the pointer leaves.
    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            needsDisplay = true
        }
    }

    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Takes whatever is left over, exactly as the plain spacer it replaces did.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        // The pointer changing is half the affordance, and it costs nothing.
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering || isCollapsed else { return }

        // A faint wash under the pointer, so the target's EXTENT is visible and not
        // only its middle. Without it the chevron reads as a tiny button rather than
        // as "this whole gap is clickable".
        if isHovering {
            NSColor.white.withAlphaComponent(0.05).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0, dy: 1),
                xRadius: Theme.Metrics.buttonCornerRadius,
                yRadius: Theme.Metrics.buttonCornerRadius
            ).fill()
        }

        let size: CGFloat = 3.5
        // Hard against the trailing edge, so the chevron sits BESIDE the enable
        // switch rather than floating in the middle of the gap. Centred, it read as
        // belonging to the effect's name; here it reads as one of the card's controls,
        // which is what it is. The click target is still the whole strip.
        let centre = NSPoint(x: bounds.maxX - size - 3, y: bounds.midY)
        let path = NSBezierPath()
        if isCollapsed {
            // Pointing right: there is more behind this.
            path.move(to: NSPoint(x: centre.x - size / 2, y: centre.y + size))
            path.line(to: NSPoint(x: centre.x + size / 2, y: centre.y))
            path.line(to: NSPoint(x: centre.x - size / 2, y: centre.y - size))
        } else {
            // Pointing down: this is open.
            path.move(to: NSPoint(x: centre.x - size, y: centre.y + size / 2))
            path.line(to: NSPoint(x: centre.x, y: centre.y - size / 2))
            path.line(to: NSPoint(x: centre.x + size, y: centre.y + size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (isHovering ? Theme.Color.textSecondary : Theme.Color.textTertiary).setStroke()
        path.stroke()
    }
}
