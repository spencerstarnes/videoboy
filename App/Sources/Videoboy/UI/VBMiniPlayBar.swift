//
//  VBMiniPlayBar.swift — the thin progress line a source shows when it is not hovered.
//
//  Purpose : A source panel's transport floats over the picture, and a full row of
//            keys sitting on the video all the time is more chrome than a glance
//            needs. At rest the panel shows this instead: one slim bar saying how
//            far through the clip the playhead is, in the shape AVKit and QuickTime
//            use. The full shuttle comes back on hover.
//  Inputs  : `progress`, 0...1.
//  Outputs : nothing — it is a readout, not a control. Scrubbing is the shuttle's
//            job, and it is one pointer-move away.
//  Connects: SourcePanelBody, which owns one of these and swaps it for the shuttle
//            on mouseEntered/mouseExited.
//  Extend  : if this ever needs to be draggable, it stops being this and becomes a
//            VBFader — do not grow a second scrubbing implementation here.
//

import AppKit

/// A slim, non-interactive playhead line.
final class VBMiniPlayBar: NSView {

    /// How far through the clip the playhead is, 0...1.
    var progress: Double = 0 {
        didSet {
            guard abs(progress - oldValue) > 0.0005 else { return }
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Theme.MiniPlayBar.height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(
            x: 0, y: (bounds.height - Theme.MiniPlayBar.thickness) / 2,
            width: bounds.width, height: Theme.MiniPlayBar.thickness)
        let radius = Theme.MiniPlayBar.thickness / 2

        Theme.Color.miniPlayBarTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }

        var filled = track
        filled.size.width = max(track.width * CGFloat(clamped), Theme.MiniPlayBar.thickness)
        Theme.Color.miniPlayBarFill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
