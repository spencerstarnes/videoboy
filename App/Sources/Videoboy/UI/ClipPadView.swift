//
//  ClipPadView.swift — one Clip Pad in the top bar, and the strip of four per side.
//
//  Purpose : The top bar's Clip Pads (docs/specs/clip-pads.md). An empty pad is a
//            barely-there recessed well; drop a clip on it and its thumbnail embeds
//            with the pad's number. Its gestures are the window's usual ones, so a
//            performer already knows them: click fires, ⌥-click takes (load, play,
//            cut), ⌥⌘-click arms it on the beat (the blue rate box appears inside the
//            pad), Shift-click learns it to MIDI, right-click clears it.
//  Inputs  : clicks, drops from any library or the Finder, state from the controller.
//  Outputs : intent, via callbacks; nothing here loads anything.
//  Connects: ClipPadController (owner of the behaviour), TransportToolbarView (where
//            the strips sit), DetectSession (Shift / ⌥⌘ highlights), VBStepButton.
//  Extend  : new pad behaviour belongs in ClipPadController; this file is the look
//            and the gestures only.
//

import AppKit
import VideoboyCore

/// One pad.
final class ClipPadView: NSView {

    static let size = NSSize(width: 46, height: 34)

    /// 0–7; the pad shows index + 1.
    let index: Int

    // MARK: State (set by the controller)

    /// The clip's thumbnail, once a clip is on the pad.
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
    /// Whether a clip is on the pad at all.
    var hasClip = false { didSet { updateToolTip(); needsDisplay = true } }
    /// The clip is opened and waiting in memory — a press will be instant.
    var isReady = false { didSet { if isReady != oldValue { needsDisplay = true } } }
    /// The pad's clip is the one in its side's source right now.
    var isLive = false { didSet { if isLive != oldValue { needsDisplay = true } } }
    /// The clip's name, for the tooltip.
    var clipName: String? { didSet { updateToolTip() } }

    /// Armed on the beat (⌥⌘): the rate. Nil when not armed.
    var flipRate: PlaybackTiming? {
        didSet {
            rateKey.isHidden = flipRate == nil
            if let flipRate { rateKey.setTiming(flipRate) }
            needsDisplay = true
        }
    }

    // MARK: Detect (Shift) and arming (⌥⌘) hints — DetectSession sets these

    var mappingSlot: String? = ClipPadController.slot
    var mappingCode: ParamCode? { ParamCode.clipPadPresses[index] }
    var onDetectRequested: ((String, ParamCode) -> Void)?
    var isDetectHighlighted = false { didSet { if isDetectHighlighted != oldValue { needsDisplay = true } } }
    var isSweepArming = false { didSet { if isSweepArming != oldValue { needsDisplay = true } } }

    // MARK: Intent

    /// A press: `take` is the ⌥ version (load, play, cut).
    var onPress: ((Int, Bool) -> Void)?
    /// ⌥⌘-click: arm or disarm on the beat.
    var onArmToggled: ((Int) -> Void)?
    /// The rate box changed.
    var onRateChanged: ((Int, PlaybackTiming) -> Void)?
    /// Something was dropped on the pad. True when it was taken.
    var onDrop: ((Int, NSPasteboard) -> Bool)?
    /// Whether a drag carries something this pad would take.
    var canAccept: ((NSPasteboard) -> Bool)?
    /// Right-click ▸ Clear Pad.
    var onClear: ((Int) -> Void)?

    /// The blue rate box, inside the pad's bottom edge, while armed. The same key as
    /// every other beat rate in the window (VBStepButton), and inside the pad's
    /// bounds so a click always reaches it.
    let rateKey = VBStepButton()

    private var isDropTarget = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(index: Int) {
        self.index = index
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Clip Pad \(index + 1)")
        registerForDraggedTypes(LibraryBrowser.droppedTypes)

        rateKey.allowsOff = false
        rateKey.isHidden = true
        rateKey.toolTip = "How often this pad fires while armed. Click faster, right-click slower."
        rateKey.onTimingChanged = { [weak self] timing in
            guard let self else { return }
            self.onRateChanged?(self.index, timing)
        }
        addSubview(rateKey)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            rateKey.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            rateKey.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            rateKey.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            rateKey.heightAnchor.constraint(equalToConstant: 13)
        ])
        updateToolTip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private func updateToolTip() {
        let number = index + 1
        toolTip = hasClip
            ? "Pad \(number): \(clipName ?? "clip") — click or press \(number) to load, again to restart; "
                + "⌥ to load, play and cut; ⌥⌘ to fire on the beat; Shift-click to learn; right-click to clear"
            : "Pad \(number): drag a clip here"
    }

    // MARK: Gestures

    /// A performance control acts on the first click, even into an inactive window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.shift), let slot = mappingSlot, let code = mappingCode {
            onDetectRequested?(slot, code)
            return
        }
        guard hasClip else { return }
        if flags.contains(.option) && flags.contains(.command) {
            onArmToggled?(index)
            return
        }
        if flags.contains(.control) {
            showMenu(for: event)
            return
        }
        // Fires on the way DOWN, like a pad: the hit is when the finger lands.
        isPressed = true
        onPress?(index, flags.contains(.option))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard hasClip else { return }
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let clear = NSMenuItem(title: "Clear Pad \(index + 1)", action: #selector(clearChosen), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func clearChosen() { onClear?(index) }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept?(sender.draggingPasteboard) == true else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        return onDrop?(index, sender.draggingPasteboard) ?? false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 4
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let well = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        if let thumbnail, hasClip {
            // The thumbnail fills the pad, cropped to its shape.
            NSGraphicsContext.saveGraphicsState()
            well.addClip()
            let imageSize = thumbnail.size
            let scale = max(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
            let drawn = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            thumbnail.draw(in: NSRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                                      width: drawn.width, height: drawn.height),
                           from: .zero, operation: .sourceOver, fraction: isPressed ? 0.6 : 1)
            // Not yet in memory: dimmed until it is, so "ready" is visible.
            if !isReady {
                NSColor.black.withAlphaComponent(0.45).setFill()
                bounds.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else if hasClip {
            Theme.Color.previewEmpty.setFill()
            well.fill()
        } else {
            // EMPTY: a very subtle recess — a shade darker than the bar, a shadow line
            // along the top edge and a faint light one along the bottom, as if pressed
            // into the bar. Texture, not a row of buttons.
            NSColor.black.withAlphaComponent(0.16).setFill()
            well.fill()
            NSGraphicsContext.saveGraphicsState()
            well.addClip()
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: bounds.maxY - 1.5, width: bounds.width, height: 1.5).fill()
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The number: always there, quiet on an empty pad, a badge on a loaded one.
        let number = "\(index + 1)" as NSString
        let font = Theme.Font.osd(size: 10)
        if hasClip {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = number.size(withAttributes: attributes)
            let badge = NSRect(x: 2, y: bounds.maxY - size.height - 3, width: size.width + 6, height: size.height + 1)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 2, yRadius: 2).fill()
            number.draw(at: NSPoint(x: badge.minX + 3, y: badge.minY), withAttributes: attributes)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: Theme.Color.textTertiary.withAlphaComponent(0.55)
            ]
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                        withAttributes: attributes)
        }

        // Rings, widest meaning first: live (accent), armed (the sweep purple every
        // automated control wears), drop target, ⌥⌘ arming pulse, Shift detect.
        func ring(_ colour: NSColor, width: CGFloat, inset: CGFloat = 1) {
            colour.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            path.lineWidth = width
            path.stroke()
        }
        if isLive { ring(Theme.Color.accent, width: 1.5) }
        if flipRate != nil { ring(Theme.Color.sweepMark, width: 1.5, inset: 2) }
        if isDropTarget { ring(Theme.Color.accent, width: 2) }
        if isSweepArming && hasClip { ring(Theme.Color.sweepArming, width: 1.5, inset: 0.5) }
        if isDetectHighlighted { ring(Theme.Color.detectHighlight, width: 1.5, inset: 0.5) }
    }
}

/// One side's four pads with its source switch on the outer end.
final class ClipPadStrip: NSView {

    let side: ClipPadBank.Side
    let pads: [ClipPadView]
    /// A|B on the left, C|D on the right: which source this side's pads load into.
    let sideSwitch = NSSegmentedControl()
    /// The switch, wrapped so Shift-click learns it (69J / 6AJ).
    let learnableSwitch: MappableControl

    /// The switch changed: the channel it now names.
    var onSideChanged: ((ClipPadBank.Side, String) -> Void)?

    init(side: ClipPadBank.Side) {
        self.side = side
        let first = side == .left ? 0 : ClipPadBank.perSide
        pads = (first..<(first + ClipPadBank.perSide)).map { ClipPadView(index: $0) }
        let channels = ClipPadBank.channels(for: side)
        sideSwitch.segmentCount = 2
        sideSwitch.setLabel(channels.first, forSegment: 0)
        sideSwitch.setLabel(channels.second, forSegment: 1)
        sideSwitch.trackingMode = .selectOne
        sideSwitch.selectedSegment = 0
        sideSwitch.controlSize = .mini
        sideSwitch.font = Theme.Font.tinyLabel
        sideSwitch.segmentStyle = .rounded
        sideSwitch.toolTip = side == .left
            ? "Pads 1–4 load into A or B"
            : "Pads 5–8 load into C or D"
        learnableSwitch = MappableControl(
            content: sideSwitch, slot: ClipPadController.slot,
            code: side == .left ? .clipPadLeftSide : .clipPadRightSide, detectFilter: .notesOnly)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        sideSwitch.target = self
        sideSwitch.action = #selector(switchChanged)

        // The switch on the OUTER end: A|B 1 2 3 4 · cluster · 5 6 7 8 C|D.
        let views: [NSView] = side == .left ? [learnableSwitch] + pads : pads + [learnableSwitch]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 5
        row.setCustomSpacing(8, after: side == .left ? learnableSwitch : pads[pads.count - 1])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Shows which channel the side loads into, without firing the callback.
    func showChannel(_ channel: String) {
        let channels = ClipPadBank.channels(for: side)
        sideSwitch.selectedSegment = channel == channels.second ? 1 : 0
    }

    @objc private func switchChanged() {
        let channels = ClipPadBank.channels(for: side)
        onSideChanged?(side, sideSwitch.selectedSegment == 1 ? channels.second : channels.first)
    }
}
