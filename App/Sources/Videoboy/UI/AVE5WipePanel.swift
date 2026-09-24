//
//  AVE5WipePanel.swift — the WJ-AVE5's WIPE MODE block, in a popover off a fader.
//
//  Purpose : When a fader's transition is AVE-5, its transition key opens this
//            instead of the pattern menu: the hardware's key block, laid out as it
//            is on the mixer, and the joystick positioner beside it. The fader is
//            still the Mix/Wipe lever — nothing here moves the picture on its own.
//  Inputs  : the block's state (`show`), clicks, drags on the positioner.
//  Outputs : `onPress` for a key, `onPositionChanged` for the positioner,
//            `onChooseTransition` to leave AVE-5, `onClose`.
//  Connects: ShellController (owns the popover and writes every change to the
//            registry), AVE5Wipe (the state and what a press does), DetectSession
//            (Shift lights every key and both positioner faders for MIDI learn),
//            Theme.AVE5.
//  Extend  : a new key is a VBAVE5Key in `buildKeyBlock`, wrapped in a
//            MappableControl with its 6xG press code so Shift can learn it.
//
//  ── LAYOUT, FROM THE HARDWARE ───────────────────────────────────────────────────
//
//      B/A    B|A    P-IN-P            ┌──────────┐
//      A/B    A|B    MULTI             │    ·     │  POSITIONER
//      ◉      ONE-WAY REVERSE          └──────────┘
//      WIPE   BACK COLOUR              X ────○────
//                                      Y ────○────
//
//  The first three rows are the WIPE MODE block exactly as it sits on the WJ-AVE5.
//  WIPE and BACK COLOUR live elsewhere on the hardware (the MIX/WIPE EFFECT block
//  and the colour selector); they are here because this popover is the only place
//  the transition's settings live. P-IN-P is drawn disabled, not left out: the
//  block is recognisable by its shape, and picture-in-picture is out of scope.
//
//  ── WHY TWO FADERS UNDER THE PAD ─────────────────────────────────────────────────
//
//  The pad is for the mouse; the faders are for MIDI. A keyboard's joystick is two
//  separate messages (usually pitch bend for X and a CC for Y), and each has to be
//  learned to its own parameter — Shift-click X, move the stick sideways;
//  Shift-click Y, move it up. One control that learned "the joystick" would have to
//  guess which axis it had just been sent.
//

import AppKit
import VideoboyCore

// MARK: - One key

/// A key of the block: its legend printed above it, an orange lamp in the cap.
final class VBAVE5Key: NSControl, AuditableControl {

    /// What is printed above the key.
    enum Legend: Equatable {
        /// The two-tone pictogram of a pattern key (A dark, B light).
        case pattern(AVE5Wipe.PatternKeys)
        /// A word, as on MULTI, ONE-WAY, REVERSE.
        case word(String)
        /// A word with a colour chip beside it, for BACK COLOUR.
        case swatch(String, NSColor)
    }

    /// The key this presses, or nil for a key that is shown but not emulated.
    let key: AVE5Wipe.Key?

    var legend: Legend {
        didSet { if legend != oldValue { needsDisplay = true } }
    }

    var isLit = false {
        didSet { if isLit != oldValue { needsDisplay = true } }
    }

    /// Called with the key when it is clicked.
    var onPress: ((AVE5Wipe.Key) -> Void)?

    /// A disabled key has nothing to reach; an enabled one must have a press handler.
    var isWiredForAudit: Bool { !isEnabled || onPress != nil }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(key: AVE5Wipe.Key?, legend: Legend) {
        self.key = key
        self.legend = legend
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.AVE5.keyWidth,
               height: Theme.AVE5.legendHeight + Theme.AVE5.legendGap + Theme.AVE5.keyHeight)
    }

    /// Acts on the first click even when the app was not frontmost, like every
    /// other performance key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, key != nil else { return }
        isPressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            isPressed = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        let fired = isPressed
        isPressed = false
        if fired { press() }
    }

    /// Presses the key as a click does. Used by the click and by self-QA.
    func press() {
        guard isEnabled, let key else { return }
        onPress?(key)
    }

    // MARK: Drawing

    /// The key cap, at the bottom of the view (AppKit's y points up).
    private var capRect: NSRect {
        NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: Theme.AVE5.keyHeight - 1)
    }

    /// The legend band above the cap.
    private var legendRect: NSRect {
        NSRect(x: 0, y: Theme.AVE5.keyHeight + Theme.AVE5.legendGap,
               width: bounds.width, height: Theme.AVE5.legendHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        drawLegend(alpha: alpha)

        let cap = NSBezierPath(roundedRect: capRect,
                               xRadius: Theme.AVE5.keyCornerRadius, yRadius: Theme.AVE5.keyCornerRadius)
        (isPressed ? Theme.AVE5.keyCapPressed : Theme.AVE5.keyCap).withAlphaComponent(alpha).setFill()
        cap.fill()
        NSColor(white: 1, alpha: 0.12 * alpha).setStroke()
        cap.lineWidth = Theme.Metrics.hairline
        cap.stroke()

        // The lamp, in the cap's left end as on the hardware.
        guard key != nil else { return }
        let diameter = Theme.AVE5.lampDiameter
        let lampRect = NSRect(x: capRect.minX + Theme.AVE5.lampInset,
                              y: capRect.midY - diameter / 2, width: diameter, height: diameter)
        (isLit ? Theme.AVE5.lamp : Theme.AVE5.lampOff).withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: lampRect).fill()
    }

    private func drawLegend(alpha: CGFloat) {
        let area = legendRect
        switch legend {
        case .word(let text):
            drawWord(text, in: area, alpha: alpha)
        case .swatch(let text, let colour):
            let chipSide = area.height - 4
            let chip = NSRect(x: area.minX, y: area.midY - chipSide / 2, width: chipSide, height: chipSide)
            colour.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor(white: 1, alpha: 0.3 * alpha).setStroke()
            NSBezierPath(roundedRect: chip, xRadius: 1.5, yRadius: 1.5).stroke()
            let rest = NSRect(x: chip.maxX + 2, y: area.minY, width: area.maxX - chip.maxX - 2, height: area.height)
            drawWord(text, in: rest, alpha: alpha)
        case .pattern(let pattern):
            Self.drawPatternLegend(pattern, in: area.insetBy(dx: 9, dy: 1), alpha: alpha)
        }
    }

    private func drawWord(_ text: String, in area: NSRect, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: Theme.AVE5.legendLight.withAlphaComponent(0.8 * alpha)
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2),
                    withAttributes: attributes)
    }

    /// The hardware's pictogram: a small screen, A dark and B light, split the way
    /// the key brings B in. The circle key is a light circle on dark.
    static func drawPatternLegend(_ pattern: AVE5Wipe.PatternKeys, in rect: NSRect, alpha: CGFloat) {
        let dark = Theme.AVE5.legendDark.withAlphaComponent(alpha)
        let light = Theme.AVE5.legendLight.withAlphaComponent(alpha)
        light.setFill()
        rect.fill()
        dark.setFill()
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        // Which half is A; the rest stays light (B). AppKit's y points up.
        var aHalf: NSRect?
        switch pattern {
        case .fromRight: aHalf = NSRect(x: rect.minX, y: rect.minY, width: halfWidth, height: rect.height)
        case .fromLeft: aHalf = NSRect(x: rect.midX, y: rect.minY, width: halfWidth, height: rect.height)
        case .fromBottom: aHalf = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: halfHeight)
        case .fromTop: aHalf = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)
        default: break
        }
        if let aHalf {
            aHalf.fill()
            drawLetter("A", in: aHalf, colour: light)
            // Every pixel of `rect` outside `aHalf` is B; label B's half.
            let bHalf: NSRect
            switch pattern {
            case .fromRight: bHalf = NSRect(x: rect.midX, y: rect.minY, width: halfWidth, height: rect.height)
            case .fromLeft: bHalf = NSRect(x: rect.minX, y: rect.minY, width: halfWidth, height: rect.height)
            case .fromBottom: bHalf = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)
            default: bHalf = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: halfHeight)
            }
            drawLetter("B", in: bHalf, colour: dark)
        } else {
            rect.fill()
            let side = rect.height - 2
            let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            light.setFill()
            NSBezierPath(ovalIn: circle).fill()
            drawLetter("B", in: circle, colour: dark)
        }
    }

    private static func drawLetter(_ letter: String, in rect: NSRect, colour: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.5, weight: .bold),
            .foregroundColor: colour
        ]
        let string = letter as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                    withAttributes: attributes)
    }
}

// MARK: - The positioner

/// The joystick positioner as a pad: drag to place the pattern's centre,
/// double-click to centre it. Only the three Ⓟ patterns follow it; for the rest the
/// dot is drawn grey, so it is plain why moving it does nothing.
final class VBAVE5Positioner: NSControl, AuditableControl {

    /// 0...1 left to right.
    private(set) var x = 0.5
    /// 0...1 top to bottom, as the picture's rows count.
    private(set) var y = 0.5

    /// Whether the current pattern follows the positioner.
    var isLive = true {
        didSet { if isLive != oldValue { needsDisplay = true } }
    }

    var onMove: ((Double, Double) -> Void)?

    var isWiredForAudit: Bool { onMove != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Positioner: moves the box, the circle and the diamond. Double-click to centre."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.AVE5.padWidth, height: Theme.AVE5.padHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows a position without reporting it.
    func setPosition(x: Double, y: Double) {
        guard x != self.x || y != self.y else { return }
        self.x = x
        self.y = y
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 {
            move(to: (0.5, 0.5))
            return
        }
        move(to: position(of: event))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            move(to: position(of: next))
            if next.type == .leftMouseUp { break }
        }
    }

    /// Moves as a drag does. Used by the drag and by self-QA.
    func move(to position: (Double, Double)) {
        setPosition(x: position.0, y: position.1)
        onMove?(x, y)
    }

    private func position(of event: NSEvent) -> (Double, Double) {
        let point = convert(event.locationInWindow, from: nil)
        let px = Double((point.x - bounds.minX) / max(bounds.width, 1))
        // AppKit's y points up; the picture's rows count down.
        let py = 1 - Double((point.y - bounds.minY) / max(bounds.height, 1))
        return (min(max(px, 0), 1), min(max(py, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let frame = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        Theme.Color.displayBackground.setFill()
        frame.fill()
        Theme.Color.displayBorder.setStroke()
        frame.lineWidth = Theme.Metrics.hairline
        frame.stroke()

        // Centre cross, where double-click returns to.
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: body.midX, y: body.minY + 4))
        cross.line(to: NSPoint(x: body.midX, y: body.maxY - 4))
        cross.move(to: NSPoint(x: body.minX + 4, y: body.midY))
        cross.line(to: NSPoint(x: body.maxX - 4, y: body.midY))
        Theme.Color.displayHighlight.setStroke()
        cross.lineWidth = Theme.Metrics.hairline
        cross.stroke()

        let diameter = Theme.AVE5.padDotDiameter
        let centre = NSPoint(x: body.minX + CGFloat(x) * body.width,
                             y: body.maxY - CGFloat(y) * body.height)
        let dot = NSRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                         width: diameter, height: diameter)
        (isLive && isEnabled ? Theme.AVE5.lamp : Theme.AVE5.lampOff).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

// MARK: - The popover's content

/// The key block and the positioner, for one fader.
final class AVE5WipePanelController: NSViewController {

    /// The bus slot this panel edits — also what every key's MIDI learn targets.
    let slot: String

    var onPress: ((AVE5Wipe.Key) -> Void)?
    var onPositionChanged: ((Double, Double) -> Void)?
    /// Opens the transition menu, anchored on the given view, to leave AVE-5.
    var onChooseTransition: ((NSView) -> Void)?
    var onClose: (() -> Void)?

    /// Every key, by what it presses. P-IN-P is not here: it presses nothing.
    private(set) var keyViews: [AVE5Wipe.Key: VBAVE5Key] = [:]
    private(set) var pipKey: VBAVE5Key?
    private(set) var positioner: VBAVE5Positioner?
    private(set) var xFader: VBFader?
    private(set) var yFader: VBFader?
    private var shapeLabel: NSTextField?
    private var transitionsButton: NSButton?

    /// The state last drawn, so a refresh that changes nothing draws nothing.
    private(set) var shown: AVE5Wipe?

    init(slot: String) {
        self.slot = slot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func loadView() {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)

        let title = Controls.label("AVE-5", font: Theme.Font.panelTitle, color: Theme.Color.textPrimary)
        let shape = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textSecondary)
        shapeLabel = shape
        // Not `Controls.glyphButton`: that pins a button to one glyph's width, and
        // this is a word. The way out of AVE-5 must stay readable; the pattern
        // description beside the title is what gives way when the header is short.
        let transitions = NSButton(title: "Transitions…", target: self, action: #selector(chooseTransition(_:)))
        transitions.isBordered = false
        transitions.bezelStyle = .inline
        transitions.font = Theme.Font.tinyLabel
        transitions.contentTintColor = Theme.Color.textSecondary
        transitions.toolTip = "Leave AVE-5 for another transition"
        transitions.setContentCompressionResistancePriority(.required, for: .horizontal)
        shape.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shape.lineBreakMode = .byTruncatingTail
        transitionsButton = transitions
        let close = Controls.glyphButton("✕", tooltip: "Close (the wipe stays armed)",
                                         target: self, action: #selector(closePanel(_:)))
        let header = NSStackView(views: [title, shape, NSView(), transitions, close])
        header.orientation = .horizontal
        header.spacing = Theme.Metrics.controlSpacing
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let block = buildKeyBlock()
        let positionerColumn = buildPositioner()
        let body = NSStackView(views: [block, positionerColumn])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = Theme.AVE5.groupSpacing

        let content = NSStackView(views: [header, body])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Theme.Metrics.controlSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        let padding = Theme.AVE5.padding
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding),
            header.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        view = root
        if let shown { show(shown, force: true) }
    }

    /// The WIPE MODE block, row by row as on the hardware.
    private func buildKeyBlock() -> NSView {
        func key(_ key: AVE5Wipe.Key, _ legend: VBAVE5Key.Legend, _ tip: String) -> NSView {
            let view = VBAVE5Key(key: key, legend: legend)
            view.toolTip = tip
            view.onPress = { [weak self] pressed in self?.onPress?(pressed) }
            keyViews[key] = view
            // Shift lights it and Shift-click learns a MIDI key to its 6xG press code.
            return MappableControl(content: view, slot: slot, code: key.triggerCode, detectFilter: .notesOnly)
        }
        let pip = VBAVE5Key(key: nil, legend: .word("P-IN-P"))
        pip.isEnabled = false
        pip.toolTip = "Picture-in-picture is not emulated"
        pipKey = pip

        let rows: [[NSView]] = [
            [key(.fromTop, .pattern(.fromTop), "B/A — B comes in from the top"),
             key(.fromLeft, .pattern(.fromLeft), "B|A — B comes in from the left"),
             pip],
            [key(.fromBottom, .pattern(.fromBottom), "A/B — B comes in from the bottom"),
             key(.fromRight, .pattern(.fromRight), "A|B — B comes in from the right"),
             key(.multi, .word("MULTI"), "MULTI — press for ×4, again for ×16, again for off")],
            [key(.circle, .pattern(.circle), "Circle — alone a circle; with the edge keys, diagonals, arrows, triangles and a diamond"),
             key(.oneWay, .word("ONE-WAY"), "ONE-WAY — the wipe keeps its direction on the way back"),
             key(.reverse, .word("REVERSE"), "REVERSE — B comes in where A would have stayed")],
            [key(.wipe, .word("NORMAL"), "WIPE — press for a border edge, again for a soft edge, again for normal"),
             key(.backColour, .swatch("COLOUR", .white), "BACK COLOUR — the border's colour; press to step through eight"),
             NSGridCell.emptyContentView]
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Theme.AVE5.keySpacing
        grid.columnSpacing = Theme.AVE5.keySpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return titled("WIPE MODE", grid)
    }

    private func buildPositioner() -> NSView {
        let pad = VBAVE5Positioner(frame: .zero)
        pad.onMove = { [weak self] x, y in
            self?.xFader?.value = x
            self?.yFader?.value = y
            self?.onPositionChanged?(x, y)
        }
        positioner = pad
        let x = Controls.fader(compact: true, mappingSlot: slot, mappingCode: .ave5PositionX,
                               target: self, action: #selector(faderMoved(_:)))
        x.toolTip = "Positioner X — Shift-click, then move your joystick sideways (pitch bend) to learn it"
        let y = Controls.fader(compact: true, mappingSlot: slot, mappingCode: .ave5PositionY,
                               target: self, action: #selector(faderMoved(_:)))
        y.toolTip = "Positioner Y — Shift-click, then move your joystick up or down to learn it"
        xFader = x
        yFader = y
        func row(_ label: String, _ fader: VBFader) -> NSView {
            let name = Controls.label(label, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            let stack = NSStackView(views: [name, fader])
            stack.orientation = .horizontal
            stack.spacing = 4
            fader.widthAnchor.constraint(equalToConstant: Theme.AVE5.padWidth - 12).isActive = true
            return stack
        }
        let column = NSStackView(views: [pad, row("X", x), row("Y", y)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return titled("POSITIONER", column)
    }

    /// A small printed heading over a group, as on the hardware panel.
    private func titled(_ title: String, _ content: NSView) -> NSView {
        let label = Controls.label(title, font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                   color: Theme.Color.textTertiary)
        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    // MARK: Showing the state

    /// Draws a state: lamps, the cycling keys' legends, the positioner. Cheap to
    /// call every frame — it does nothing unless the state changed.
    func show(_ state: AVE5Wipe, force: Bool = false) {
        guard force || state != shown else { return }
        shown = state
        guard isViewLoaded else { return }
        for (key, view) in keyViews {
            view.isLit = state.isLit(key)
        }
        keyViews[.multi]?.legend = .word(state.multi.label)
        keyViews[.wipe]?.legend = .word(state.edge.label)
        let rgb = state.backColour.rgb
        keyViews[.backColour]?.legend = .swatch(
            "COLOUR", NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
        keyViews[.backColour]?.toolTip = "BACK COLOUR — \(state.backColour.displayName). "
            + "The border's colour; press to step through eight"
        positioner?.setPosition(x: state.positionX, y: state.positionY)
        positioner?.isLive = state.isPositionable
        xFader?.value = state.positionX
        yFader?.value = state.positionY
        var description = state.shape.displayName
        if state.multi != .off { description += " \(state.multi.label)" }
        if state.edge != .normal { description += " · \(state.edge.label.lowercased())" }
        if state.isPositionable { description += " · Ⓟ" }
        shapeLabel?.stringValue = description
    }

    // MARK: Actions

    @objc private func faderMoved(_ sender: VBFader) {
        let x = xFader?.value ?? 0.5
        let y = yFader?.value ?? 0.5
        positioner?.setPosition(x: x, y: y)
        onPositionChanged?(x, y)
    }

    @objc private func chooseTransition(_ sender: NSButton) {
        onChooseTransition?(sender)
    }

    @objc private func closePanel(_ sender: NSButton) {
        onClose?()
    }
}
