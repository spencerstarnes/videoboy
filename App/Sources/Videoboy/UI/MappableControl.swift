//
//  MappableControl.swift — a menu, a switch or a colour well that Shift can find.
//
//  Purpose : Shift-to-detect lights every control that can be put under a knob. It knew
//            about faders and action keys, which was every mappable control right up
//            until the EMU panel stopped using a fader for everything. A menu is a
//            perfectly good thing to put a knob on — it steps through its items — and a
//            switch is a perfectly good thing to put a pad on.
//  Inputs  : a slot, a param code, and the widget being wrapped.
//  Outputs : the detect highlight, and a request when Shift-clicked.
//  Connects: DetectSession (which lights these), EmuBrowserView (which builds them).
//  Extend  : wrap any control that carries a param code. Do NOT add a second highlight
//            mechanism — one gesture revealing everything only holds if everything
//            answers to the same one.
//

import AppKit
import VideoboyCore

/// Wraps a control that is not a fader so it can still be learned to MIDI.
final class MappableControl: NSView {

    let mappingSlot: String
    let mappingCode: ParamCode
    /// What kind of message this control should learn.
    let detectFilter: MIDIInput.DetectFilter

    var onDetectRequested: ((String, ParamCode, MIDIInput.DetectFilter) -> Void)?

    /// Whether Shift is held and this control is offering itself.
    var isDetectHighlighted = false {
        didSet {
            guard isDetectHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    private let content: NSView

    init(
        content: NSView, slot: String, code: ParamCode,
        detectFilter: MIDIInput.DetectFilter
    ) {
        self.content = content
        self.mappingSlot = slot
        self.mappingCode = code
        self.detectFilter = detectFilter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        guard isDetectHighlighted else { return }
        // The same ring a fader draws, so one gesture produces one look across the
        // whole window rather than a different hint per kind of control.
        let inset = bounds.insetBy(dx: 1, dy: 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let ring = NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3)
        Theme.Color.detectHighlight.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }

    /// Shift-click arms it; an ordinary click goes to the control inside.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isDetectHighlighted else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isDetectHighlighted else { return super.mouseDown(with: event) }
        onDetectRequested?(mappingSlot, mappingCode, detectFilter)
    }
}
