//
//  VBMiniPlayBar.swift — the playhead strip on a source's picture.
//
//  Purpose : Always on the image, always showing where the playhead is, and
//            scrubbable by dragging it. The shuttle keys fade in ABOVE it on hover;
//            this stays put, because a scrubber that appears only while the pointer
//            is already over it is one you cannot aim at.
//  Inputs  : `progress`, and the in/out marks the clip is trimmed to.
//  Outputs : `onScrub`, while being dragged.
//  Connects: SourcePanelBody (which owns one per source), ShellController (which
//            feeds it the playhead and the marks, and takes its scrubs).
//  Extend  : this is the whole scrubbing surface for a source. If it needs to show
//            something else about the clip, draw it here rather than adding a second
//            strip beside it.
//
//  The marks are drawn because a trimmed clip that looks identical to an untrimmed
//  one is how in and out points come to seem broken — the operator sets them, sees no
//  difference, and concludes nothing happened.
//

import AppKit
import VideoboyCore

/// A slim playhead strip that can be dragged.
final class VBMiniPlayBar: NSView {

    /// How far through the clip the playhead is, 0...1.
    var progress: Double = 0 {
        didSet {
            guard abs(progress - oldValue) > 0.0005 else { return }
            needsDisplay = true
        }
    }

    /// The trimmed range, when the clip has one. Drawn as a lit span with a tick at
    /// each end.
    var markedRange: ClosedRange<Double>? {
        didSet {
            guard markedRange != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Called continuously while the strip is dragged, with the new position.
    var onScrub: ((Double) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Theme.MiniPlayBar.height)
    }

    override var isFlipped: Bool { true }

    // MARK: - Drawing

    private var trackRect: NSRect {
        NSRect(
            x: 0, y: (bounds.height - Theme.MiniPlayBar.thickness) / 2,
            width: bounds.width, height: Theme.MiniPlayBar.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = Theme.MiniPlayBar.thickness / 2

        Theme.Color.miniPlayBarTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        func x(_ position: Double) -> CGFloat {
            track.minX + track.width * CGFloat(min(max(position, 0), 1))
        }

        // The trimmed span, under the playhead fill so the playhead stays readable
        // while inside it.
        if let range = markedRange {
            Theme.Color.sweepMark.setFill()
            let from = x(range.lowerBound)
            let to = x(range.upperBound)
            NSBezierPath(
                roundedRect: NSRect(x: from, y: track.minY, width: max(to - from, 1), height: track.height),
                xRadius: radius, yRadius: radius
            ).fill()

            // A tick at each end, taller than the track, so a very short trim is still
            // visible as two marks rather than a smudge.
            for position in [range.lowerBound, range.upperBound] {
                NSBezierPath(rect: NSRect(
                    x: x(position) - 1, y: track.minY - 3,
                    width: 2, height: track.height + 6)).fill()
            }
        }

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }
        var filled = track
        filled.size.width = max(track.width * CGFloat(clamped), Theme.MiniPlayBar.thickness)
        Theme.Color.miniPlayBarFill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: - Scrubbing

    override func mouseDown(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil))

        // Tracked here rather than through mouseDragged, so the scrub keeps following
        // the pointer once it leaves this strip — which it will immediately, because
        // the strip is a few points tall.
        var dragging = true
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                scrub(to: convert(next.locationInWindow, from: nil))
            case .leftMouseUp:
                dragging = false
            default:
                break
            }
        }
    }

    private func scrub(to point: NSPoint) {
        let track = trackRect
        guard track.width > 0 else { return }
        let position = Double((point.x - track.minX) / track.width)
        let clamped = min(max(position, 0), 1)
        progress = clamped
        onScrub?(clamped)
    }
}
