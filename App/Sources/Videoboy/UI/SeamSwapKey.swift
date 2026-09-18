//
//  SeamSwapKey.swift — the ⇅ key that sits on the join between two source windows.
//
//  Purpose : Exchanges the clips in the pair of channels it straddles. It lives ON the
//            hairline between the two previews because that is what it means: the
//            thing above and the thing below change places.
//  Inputs  : a click.
//  Outputs : `onPressed`.
//  Connects: PanelGridView (which positions it on the seam), ShellController (which
//            wires it to `Engine.swapChannels`).
//  Extend  : nothing else belongs on the seam. It is the narrowest piece of furniture
//            in the window and a second key there would make both hard to hit.
//
//  WHY NOT A KEY ON THE FADER ROW, where CUT and FADE live. That row is about WHEN a
//  source reaches air. This is about WHICH CHANNEL A CLIP IS IN — a different question,
//  and one whose answer is visible in the two windows rather than in the fader. Sitting
//  between them, it points at the two things it operates on, and there is no legend to
//  read to work out which pair it applies to.
//

import AppKit
import VideoboyCore

/// A small round key drawn over the join between two stacked source panels.
///
/// `AuditableControl` because this is closure-driven: it has no target/action, so the
/// control audit would otherwise count it as enabled-but-unwired — the one state that
/// fails the check, and rightly, since it means a control that looks usable and is not.
final class SeamSwapKey: NSControl, AuditableControl {

    /// Wired when something is listening for the press.
    var isWiredForAudit: Bool { onPressed != nil }

    /// Pressed.
    var onPressed: (() -> Void)?

    /// The two channels it exchanges, for the tooltip and the log.
    private let upper: String
    private let lower: String

    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Big enough to hit without looking, small enough not to cover either picture.
    /// A performance reaches for this mid-set, so it is sized for a thumb rather than
    /// for the hairline it sits on.
    static let diameter: CGFloat = 26

    init(upper: String, lower: String) {
        self.upper = upper
        self.lower = lower
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        toolTip = "Swap the clips in \(upper) and \(lower). Each keeps playing from "
            + "where it was, and the fader does not move — so what is on air stays on "
            + "air. Effects and damage belong to the channel and stay put."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    // The seam is a boundary between two panels, so the key has to claim its clicks
    // explicitly — otherwise they fall through to whichever panel is underneath and
    // the key looks dead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside else { return }
        onPressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // JUST THE GLYPH. No fill, no border, no bezel.
        //
        // It was a filled round key sitting on the hairline, and a filled shape on a
        // boundary interrupts every line that passes under it — the panel borders and
        // the join itself. The arrows alone say the same thing and leave the window's
        // ruling intact, which is the whole point of a layout built out of straight
        // lines meeting exactly.
        //
        // It is still a control: the hit area is the full frame, comfortably larger
        // than the glyph, so it stays something you can aim at in a dark room.
        let glyph = "\u{21C5}" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isPressed
                ? Theme.Color.focusOn
                : Theme.Color.textSecondary
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}
