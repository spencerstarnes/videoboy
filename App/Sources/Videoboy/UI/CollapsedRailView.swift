//
//  CollapsedRailView.swift — the thin strip a collapsed panel group leaves behind.
//
//  Purpose : Resolve-style panel collapsing: a group folds to the edge of the window
//            and leaves a narrow labelled rail you can click to bring it back. The
//            rail is what stops a collapsed group from simply vanishing, which would
//            leave no way to restore it and no clue it ever existed.
//  Inputs  : a title and which edge it sits on.
//  Outputs : target/action when clicked.
//  Connects: PanelGridView, which swaps a group's panels for one of these.
//

import AppKit
import VideoboyCore

/// A narrow vertical strip standing in for a collapsed group.
final class CollapsedRailView: NSControl {

    /// The group's name, drawn rotated down the rail.
    let title: String
    /// Which side of the window this rail is on, which decides the chevron direction.
    let isLeadingEdge: Bool

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(title: String, isLeadingEdge: Bool) {
        self.title = title
        self.isLeadingEdge = isLeadingEdge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        layer?.masksToBounds = true
        toolTip = "Show \(title)"
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

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHovering ? Theme.Color.panelFill : Theme.Color.panelFillNested).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Theme.Metrics.panelCornerRadius,
            yRadius: Theme.Metrics.panelCornerRadius
        ).fill()

        // The chevron points the way the group will come back from.
        let chevron = isLeadingEdge ? "›" : "‹"
        let chevronAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: isHovering ? Theme.Color.textPrimary : Theme.Color.textSecondary
        ]
        let chevronText = chevron as NSString
        let chevronSize = chevronText.size(withAttributes: chevronAttributes)
        chevronText.draw(
            at: NSPoint(x: (bounds.width - chevronSize.width) / 2, y: bounds.height - chevronSize.height - 6),
            withAttributes: chevronAttributes
        )

        // The title runs down the rail. Rotated rather than truncated to one letter,
        // so a collapsed group still says what it is.
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.tinyLabel,
            .foregroundColor: isHovering ? Theme.Color.textSecondary : Theme.Color.textTertiary
        ]
        let titleText = title as NSString
        let titleSize = titleText.size(withAttributes: titleAttributes)

        // Only draw the title if the rail is tall enough to hold it; a squeezed rail
        // with text spilling out of it looks broken.
        guard bounds.height > titleSize.width + 30 else { return }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.width / 2 + titleSize.height / 2,
                             yBy: bounds.height - chevronSize.height - 14)
        transform.rotate(byDegrees: -90)
        transform.concat()
        titleText.draw(at: .zero, withAttributes: titleAttributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
