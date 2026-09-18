//
//  VBSlideToggle.swift — a three-way switch whose knob slides between positions.
//
//  Purpose : The fade-rate control — turtle, middle, hare. An NSSegmentedControl says
//            the same thing, but it says it by lighting a different cell, and a control
//            that JUMPS reads as three buttons that happen to be touching. A knob that
//            travels reads as one control with a position, which is what a rate is.
//  Inputs  : clicks, and the index set from outside.
//  Outputs : the usual target/action, with `selectedIndex`.
//  Connects: FaderPanelBody (the fade rate), Theme.
//  Extend  : more than about four positions and this stops being a switch and starts
//            being a slider — use a fader instead.
//
//  ── WHY THIS IS NOT AN NSSEGMENTEDCONTROL ───────────────────────────────────────
//
//  It was one, and the height was the first problem: `.rounded` is a fixed-height
//  bezel, so a height constraint grows the view and centres the control inside it,
//  leaving it visibly shorter than the keys beside it. `.separated` fixes that and
//  gives three separate capsules — which looks like three buttons, not one switch.
//
//  AppKit has no animated segmented control. The sliding selection people picture is
//  UIKit's, and on the Mac it is drawn per-app. So this is drawn per-app: a track, a
//  knob that animates to the position clicked, and the icons on top.
//

import AppKit

/// A switch with several positions and a knob that slides between them.
final class VBSlideToggle: NSControl {

    /// The icons, one per position, left to right.
    private let images: [NSImage]
    /// What each position means, for the tooltips.
    private let tooltips: [String]

    /// Which position is chosen.
    var selectedIndex: Int = 1 {
        didSet {
            guard selectedIndex != oldValue else { return }
            moveKnob(animated: true)
            updateIcons()
        }
    }

    private let knobLayer = CALayer()

    /// The icons, one layer each, ABOVE the knob.
    ///
    /// They were drawn in `draw(_:)`, which paints the view's own backing — and a
    /// sublayer always composites on top of that, so the knob covered whichever icon
    /// was selected. The one icon you most need to see was the one hidden.
    private var iconLayers: [CALayer] = []
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    init(images: [NSImage], tooltips: [String], selected: Int = 1) {
        self.images = images
        self.tooltips = tooltips
        super.init(frame: .zero)
        self.selectedIndex = min(max(selected, 0), max(images.count - 1, 0))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Theme.OptionButton.cornerRadius
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = Theme.Metrics.hairline
        layer?.borderColor = Theme.Color.panelBorder.cgColor

        knobLayer.cornerRadius = Theme.OptionButton.cornerRadius - 1
        knobLayer.backgroundColor = Theme.Color.accent.cgColor
        layer?.addSublayer(knobLayer)

        // Added AFTER the knob, so they sit on top of it.
        for _ in images {
            let iconLayer = CALayer()
            iconLayer.contentsGravity = .center
            layer?.addSublayer(iconLayer)
            iconLayers.append(iconLayer)
        }
        updateIcons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Wide enough for its positions, and exactly as tall as the keys beside it.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: CGFloat(images.count) * 26 + 4,
            height: Theme.BusButton.height)
    }

    override func layout() {
        super.layout()
        moveKnob(animated: false)
        updateIcons()
    }

    /// The rectangle a position's knob occupies.
    private func knobFrame(for index: Int) -> CGRect {
        guard !images.isEmpty else { return .zero }
        let inset: CGFloat = 2
        let width = (bounds.width - inset * 2) / CGFloat(images.count)
        return CGRect(
            x: inset + CGFloat(index) * width, y: inset,
            width: width, height: bounds.height - inset * 2)
    }

    private func moveKnob(animated: Bool) {
        let target = knobFrame(for: selectedIndex)
        guard animated else {
            // Implicit animations off, or every layout pass animates the knob from
            // wherever it happened to be — including on the first one, which would
            // make the control slide in from the left edge every time the panel is
            // built.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            knobLayer.frame = target
            CATransaction.commit()
            return
        }
        // Short, and eased. Long enough to read as movement rather than a jump, short
        // enough that it never gets in the way of the next click.
        let animation = CABasicAnimation(keyPath: "frame")
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        knobLayer.add(animation, forKey: "slide")
        knobLayer.frame = target
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = position(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        toolTip = index.map { tooltips.indices.contains($0) ? tooltips[$0] : nil } ?? nil
        updateIcons()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        updateIcons()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let index = position(at: convert(event.locationInWindow, from: nil))
        else { return }
        guard index != selectedIndex else { return }
        selectedIndex = index
        sendAction(action, to: target)
    }

    private func position(at point: NSPoint) -> Int? {
        guard !images.isEmpty, bounds.contains(point) else { return nil }
        let index = Int(point.x / (bounds.width / CGFloat(images.count)))
        return min(max(index, 0), images.count - 1)
    }

    // MARK: - Icons

    /// Positions and tints the icons.
    ///
    /// Tinted through the SYMBOL CONFIGURATION rather than by drawing the image and
    /// flooding it with `.sourceAtop`. The flood trick works on a solid glyph and
    /// washes out an SF Symbol, whose strokes are antialiased into partial alpha —
    /// which is why the icons first came out ghostly.
    private func updateIcons() {
        guard iconLayers.count == images.count else { return }
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, image) in images.enumerated() {
            let tint: NSColor
            if index == selectedIndex {
                tint = .white
            } else if index == hoveredIndex {
                tint = Theme.Color.textPrimary
            } else {
                tint = Theme.Color.textSecondary
            }

            let configuration = NSImage.SymbolConfiguration(
                pointSize: 12, weight: .semibold
            ).applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            let drawn = image.withSymbolConfiguration(configuration) ?? image

            let cell = knobFrame(for: index)
            let size = drawn.size
            let iconLayer = iconLayers[index]
            iconLayer.contentsScale = scale
            iconLayer.contents = drawn.cgImage(
                forProposedRect: nil, context: nil, hints: nil)
            iconLayer.frame = CGRect(
                x: cell.midX - size.width / 2, y: cell.midY - size.height / 2,
                width: size.width, height: size.height)
            iconLayer.opacity = isEnabled ? 1 : 0.4
        }
        CATransaction.commit()
    }
}
