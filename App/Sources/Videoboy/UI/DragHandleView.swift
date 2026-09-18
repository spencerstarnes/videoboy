//
//  DragHandleView.swift — the three-dash grip that reorders effects.
//
//  Purpose : Gives an effect card something to grab. Three dashes is the convention
//            everywhere from Photoshop's layer list to a sortable table row, so it
//            needs no explanation.
//  Inputs  : mouse drags.
//  Outputs : `onDrag`, with the vertical distance moved, and `onDragEnded`.
//  Connects: EffectChainPanelBody, which turns the movement into a reorder.
//  Extend  : nothing here should know what is being reordered. It reports movement.
//

import AppKit

/// A grip that reports vertical drags.
final class DragHandleView: NSView {

    /// Called continuously while dragging, with the pointer in WINDOW coordinates.
    ///
    /// Window coordinates, not a local offset. A local offset has to be interpreted by
    /// whoever receives it, and this handle sits inside a card, inside a stack, inside
    /// a FLIPPED document, inside a scroll view — four spaces, two of which disagree
    /// about which way y runs. Reporting the window point means the receiver converts
    /// once, into the space it actually lays out in, and there is no sign to get wrong.
    /// Getting it wrong is what made the gap move the opposite way to the pointer.
    var onDrag: ((NSPoint) -> Void)?
    /// Called once when a drag actually starts, before the first movement.
    ///
    /// Separate from `onDrag` because lifting the card, dimming the list and building a
    /// floating snapshot are all things that must happen ONCE — doing them on the first
    /// movement means doing them again on the second.
    var onDragBegan: ((NSPoint) -> Void)?
    /// Called when the drag finishes.
    var onDragEnded: (() -> Void)?

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.Metrics.dragHandleWidth, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let colour = isHovering ? Theme.Color.textSecondary : Theme.Color.textTertiary
        colour.setFill()

        // Three dashes, centred.
        let dashWidth = bounds.width - 3
        let dashHeight: CGFloat = 1.5
        let spacing: CGFloat = 4
        let totalHeight = dashHeight * 3 + spacing * 2
        var y = (bounds.height - totalHeight) / 2
        for _ in 0..<3 {
            let dash = NSRect(x: 1.5, y: y, width: dashWidth, height: dashHeight)
            NSBezierPath(roundedRect: dash, xRadius: 0.75, yRadius: 0.75).fill()
            y += dashHeight + spacing
        }
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        let start = convert(event.locationInWindow, from: nil)
        var dragging = true
        var hasBegun = false
        // A few points of slop before a drag starts, so a click that wobbles does not
        // lift the card and dim the whole panel for nothing.
        let threshold: CGFloat = 3
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !hasBegun {
                    guard abs(point.y - start.y) > threshold else { break }
                    hasBegun = true
                    onDragBegan?(next.locationInWindow)
                }
                onDrag?(next.locationInWindow)
            case .leftMouseUp:
                dragging = false
            default:
                break
            }
        }
        onDragEnded?()
        NSCursor.openHand.set()
    }
}
