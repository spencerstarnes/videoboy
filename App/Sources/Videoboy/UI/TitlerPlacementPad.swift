//
//  TitlerPlacementPad.swift — put the text where you want it, by pointing at it.
//
//  Purpose : Position the title by dragging inside a picture of the screen, instead of
//            by moving two unrelated faders and reading the result on a monitor.
//  Inputs  : a drag, and the panel's current position.
//  Outputs : `onPlaced(x, y)` in 0...1, the same units every other control here uses.
//  Connects: EmuBrowserView, ScalaTitlerPanel's textX / textY.
//  Extend  : this is a PLACEMENT control, not a preview. It draws where the text sits,
//            not what it looks like — the picture of what it looks like is the EMU
//            screen above it, which is the machine's own output.
//
//  ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────
//
//  Position was two faders, X and Y. That is fine for automation and hopeless for a
//  hand: placing a caption meant moving one fader, looking up at the output, moving the
//  other, looking up again, and repeating — because neither fader tells you anything
//  about where the text IS, only about one axis of where it is going.
//
//  During a show you have one hand and about a second. Pointing at the place you want
//  the words is the whole gesture. The faders remain underneath for MIDI and for
//  automation, because a knob cannot point.
//
//  The title-safe area is drawn because this app's output is an analog SD display, and
//  the difference between a caption inside that rectangle and one outside it is the
//  difference between a caption and a caption with its edges eaten.
//

import AppKit
import VideoboyCore

/// A 4:3 rectangle you drag in to place the title.
final class TitlerPlacementPad: NSControl, AuditableControl {

    /// Where the text is, 0...1 across and down. Set to follow the panel.
    var position: CGPoint = CGPoint(x: 0.5, y: 0.5) {
        didSet {
            guard position != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Called as the text is dragged, with 0...1 coordinates.
    var onPlaced: ((Double, Double) -> Void)?

    /// What the title currently says, drawn so the pad shows the words rather than an
    /// abstract dot. Live text is what makes it obvious which line you are moving.
    var caption: String = "" {
        didSet {
            guard caption != oldValue else { return }
            needsDisplay = true
        }
    }

    var isWiredForAudit: Bool { onPlaced != nil }

    /// The share of the picture that is title-safe, matching the panel's own faders.
    private let titleSafeInset: CGFloat = 0.1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Drag to place the title. The inner rectangle is the title-safe area — "
            + "anything outside it is eaten by overscan on an analog display."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 96)
    }

    override var isFlipped: Bool { true }

    // MARK: - Pointing at it

    override func mouseDown(with event: NSEvent) { place(event) }
    override func mouseDragged(with event: NSEvent) { place(event) }

    private func place(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let picture = pictureRect
        guard picture.width > 0, picture.height > 0 else { return }

        // Clamped to TITLE SAFE, not to the pad. The faders cannot reach outside it
        // either, so a pad that could would be offering a placement the rest of the
        // panel refuses — and the text would snap somewhere else on the next refresh.
        let inset = picture.insetBy(
            dx: picture.width * titleSafeInset, dy: picture.height * titleSafeInset)
        let x = min(max((local.x - inset.minX) / inset.width, 0), 1)
        let y = min(max((local.y - inset.minY) / inset.height, 0), 1)
        position = CGPoint(x: x, y: y)
        onPlaced?(Double(x), Double(y))
    }

    // MARK: - Drawing

    /// The 4:3 picture inside the pad, centred.
    private var pictureRect: NSRect {
        let aspect: CGFloat = 4.0 / 3.0
        var rect = bounds.insetBy(dx: 2, dy: 2)
        if rect.width / rect.height > aspect {
            let width = rect.height * aspect
            rect.origin.x += (rect.width - width) / 2
            rect.size.width = width
        } else {
            let height = rect.width / aspect
            rect.origin.y += (rect.height - height) / 2
            rect.size.height = height
        }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        let picture = pictureRect

        // The screen: black, because that is what the titler's background is.
        NSColor.black.setFill()
        NSBezierPath(rect: picture).fill()
        Theme.Color.panelBorder.setStroke()
        NSBezierPath(rect: picture).stroke()

        // Title safe.
        let safe = picture.insetBy(
            dx: picture.width * titleSafeInset, dy: picture.height * titleSafeInset)
        let guide = NSBezierPath(rect: safe)
        guide.setLineDash([3, 3], count: 2, phase: 0)
        Theme.Color.textTertiary.setStroke()
        guide.stroke()

        // Where the words are. Drawn as the words themselves when there are any —
        // a dot tells you a coordinate, the text tells you what you are moving.
        let point = NSPoint(
            x: safe.minX + safe.width * position.x,
            y: safe.minY + safe.height * position.y)

        let shown = caption.isEmpty ? "—" : caption
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.Color.textPrimary
        ]
        let text = shown as NSString
        let size = text.size(withAttributes: attributes)

        // Centred on the point, because the titler centres its text on the position it
        // is given — so the pad has to show the same relationship or it lies about
        // where the words will land.
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, picture.minX), picture.maxX - size.width)
        origin.y = min(max(origin.y, picture.minY), picture.maxY - size.height)
        text.draw(at: origin, withAttributes: attributes)

        // Crosshair, so the exact anchor is visible when the text is long.
        Theme.Color.focusOn.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: point.x - 4, y: point.y))
        cross.line(to: NSPoint(x: point.x + 4, y: point.y))
        cross.move(to: NSPoint(x: point.x, y: point.y - 4))
        cross.line(to: NSPoint(x: point.x, y: point.y + 4))
        cross.lineWidth = 1
        cross.stroke()
    }
}
