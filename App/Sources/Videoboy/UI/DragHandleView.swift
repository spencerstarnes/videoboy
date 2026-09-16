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

    /// Called continuously while dragging, with the offset from where the drag began.
    var onDrag: ((CGFloat) -> Void)?
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
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                onDrag?(point.y - start.y)
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
