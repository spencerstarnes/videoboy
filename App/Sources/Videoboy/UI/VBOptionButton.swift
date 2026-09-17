//
//  VBOptionButton.swift — the compact lit toggle used along the output bar.
//
//  Purpose : The bar was caption-plus-NSSwitch pairs. Each pair is a 28pt switch, a
//            word, and the gap between them — three elements to say one boolean, six
//            times over, which is what made the strip chunky. Resolve, FCP X and
//            Photoshop all answer this the same way: a small button carrying its own
//            label, lit when on. One element, no caption, and the state is the
//            colour rather than the position of a knob.
//  Inputs  : a title, and whether it is on.
//  Outputs : a click, and a right-click when the option has settings behind it.
//  Connects: SettingsBarPanelBody, Theme.
//  Extend  : options with detail behind them use the CONTEXT MENU, never a chevron.
//            A truncated mini popup next to a toggle is two controls where one will
//            do, and it is the thing that made this bar look busy.
//
//  Sized from AppKit's own mini metrics (16pt) rather than invented numbers, so it
//  sits correctly beside the system controls it shares the bar with.
//

import AppKit
import VideoboyCore

/// A small toggle that carries its own label and lights when on.
final class VBOptionButton: NSControl {

    private(set) var title: String

    /// Changes the label, for keys that cycle through states.
    func setTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The colour of the lit state. Defaults to the accent; the output enable uses
    /// tally red, because that one means "on air" rather than "option selected".
    var onColour: NSColor = Theme.Color.accent

    /// Called on right-click, for options that have settings behind them.
    var onSecondaryClick: ((NSView) -> Void)?

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String, onColour: NSColor = Theme.Color.accent) {
        self.title = title
        self.onColour = onColour
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        let text = title as NSString
        let width = text.size(withAttributes: [.font: Theme.Font.tinyLabel]).width
        return NSSize(
            width: ceil(width) + Theme.OptionButton.horizontalPadding * 2,
            height: Theme.OptionButton.height)
    }

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
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    /// Every option button beneath a view.
    static func all(in view: NSView) -> [VBOptionButton] {
        var found: [VBOptionButton] = []
        if let key = view as? VBOptionButton { found.append(key) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    // MARK: Detect
    //
    // An action key can be learned to a MIDI button exactly as a fader can be learned
    // to a knob. The gesture is the same one — hold Shift, click the control — so a
    // performer does not have to know which kind of thing they are pointing at.

    /// The slot and code this key stands for, when it can be learned.
    var mappingSlot: String?
    var mappingCode: ParamCode?

    /// Called when the key is shift-clicked while detect is available.
    var onDetectRequested: ((String, ParamCode) -> Void)?

    /// Lit while Shift is held and this key can be learned.
    var isDetectHighlighted = false {
        didSet {
            guard isDetectHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift),
           let slot = mappingSlot, let code = mappingCode {
            onDetectRequested?(slot, code)
            return
        }
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if isPressed != inside {
                isPressed = inside
                needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }

        let fired = isPressed
        isPressed = false
        if fired {
            isOn.toggle()
            sendAction(action, to: target)
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        onSecondaryClick(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.OptionButton.cornerRadius,
            yRadius: Theme.OptionButton.cornerRadius)

        // Lit means on. Off is a hairline outline rather than a filled slab, so a bar
        // of mostly-off options reads as quiet instead of as a row of grey blocks.
        if isOn {
            var fill = onColour
            if isPressed { fill = fill.blended(withFraction: 0.3, of: .black) ?? fill }
            else if isHovering { fill = fill.blended(withFraction: 0.15, of: .white) ?? fill }
            fill.setFill()
            path.fill()
        } else {
            if isPressed || isHovering {
                NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.09).setFill()
                path.fill()
            }
            Theme.Color.panelBorder.setStroke()
            path.lineWidth = Theme.Metrics.hairline
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.tinyLabel,
            .foregroundColor: isOn
                ? NSColor.white
                : Theme.Color.textSecondary.withAlphaComponent(isEnabled ? 1 : 0.4)
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes)
    }
}
