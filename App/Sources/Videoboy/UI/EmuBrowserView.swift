//
//  EmuBrowserView.swift — the EMU tab: a machine, and the controls that drive it.
//
//  Purpose : Shows the emulated machine in the asset browser, with a fader for each
//            thing the software inside it can really do. Picking it up and dropping it
//            on a source window assigns it, like any other asset.
//  Inputs   : EmulatorController — which owns the machine, the link and the values.
//  Outputs  : control movements, text, and the four buttons that run the machine.
//  Connects : LibraryPanelBody (which shows this as a tab), EmulatorController,
//             ScalaTitlerPanel (whose controls this draws).
//  Extend   : DO NOT add a fader here. Add it to the program's control set, where it
//             has to declare which real function it reaches — this view draws whatever
//             that list contains and nothing else. That rule is the only thing keeping
//             the panel honest.
//
//  ── WHY IT LOOKS LIKE A MACHINE AND NOT A FORM ──────────────────────────────────
//
//  Because the thing being driven is a machine, and the operator needs to know its
//  state before touching anything: is it set up, is it running, is the link answering,
//  is the software's script port actually open. Four questions, four different
//  failures, and "nothing happens" is the symptom of all of them. So the status line
//  says which one, in words, above controls that grey out when they cannot act.
//

import AppKit
import VideoboyCore

/// The EMU tab's contents.
final class EmuBrowserView: NSStackView {

    private let controller: EmulatorController

    private let statusLabel = Controls.label(
        "", font: Theme.Font.tinyLabel, color: Theme.Color.textSecondary)
    private let machineLabel = Controls.label(
        "", font: Theme.Font.label, color: Theme.Color.textPrimary)
    private var startButton: VBOptionButton?
    private var setUpButton: VBOptionButton?
    private var showButton: VBOptionButton?
    private var stateButton: VBOptionButton?
    private let linkDot = LinkIndicatorView()

    /// The machine's screen, IN the browser. The emulator's own window is a separate
    /// application's and floats; this is the one you look at.
    private let screen = EmuScreenView()

    private var faders: [TitlerFunction: VBFader] = [:]
    private var menus: [TitlerFunction: NSPopUpButton] = [:]
    private var switches: [TitlerFunction: NSSwitch] = [:]
    private var wells: [TitlerFunction: NSColorWell] = [:]
    private var readouts: [TitlerFunction: NSTextField] = [:]
    /// Which control a menu, switch or well drives. Keyed by identity because an
    /// NSPopUpButton has no room to carry one and a tag is an Int.
    private var mappingByControl: [ObjectIdentifier: TitlerFunction] = [:]
    private var textFieldsByLine: [Int: NSTextField] = [:]
    private var takeButton: VBOptionButton?

    /// Called when the machine is dragged onto a source, with the channel letter.
    var onAssignedToChannel: ((String) -> Void)?

    init(controller: EmulatorController) {
        self.controller = controller
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false

        buildMachineRow()
        buildScreen()
        buildTransportRow()
        buildTextRow()
        buildControls()

        controller.onStateChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Building

    private func buildMachineRow() {
        let tile = EmuMachineTile(
            title: controller.program.machine.displayName,
            subtitle: controller.program.name)
        tile.onDroppedOnChannel = { [weak self] letter in
            self?.onAssignedToChannel?(letter)
        }

        machineLabel.stringValue = controller.program.name
        let column = Controls.column([
            machineLabel,
            Controls.label(
                controller.program.machine.displayName,
                font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        ], spacing: 1)

        let row = Controls.row([tile, column, Controls.spacer(), linkDot], spacing: 8)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// The live picture, directly under the machine's name.
    ///
    /// Above the controls rather than below them, because it is the thing being
    /// changed — a fader you cannot see the result of is a fader you move twice.
    private func buildScreen() {
        screen.onOpenMachine = { [weak self] in self?.controller.showMachine() }
        screen.onPictureAppeared = { [weak self] in self?.refresh() }
        addArrangedSubview(screen)
        // A FIXED HEIGHT, not a 4:3 box the width of the panel.
        //
        // At panel width, 4:3 is over three hundred points and pushes all nineteen
        // faders below the fold — and the whole reason the screen is here is to watch
        // what the faders do. The picture letterboxes inside this band (the layer's
        // gravity keeps its shape), so nothing is distorted; there is just less of it,
        // which is the right trade in a monitor.
        NSLayoutConstraint.activate([
            screen.widthAnchor.constraint(equalTo: widthAnchor),
            screen.heightAnchor.constraint(equalToConstant: 150)
        ])
    }

    private func buildTransportRow() {
        let setUp = VBOptionButton(title: "SET UP")
        setUp.toolTip = "Find your Amiga disc, build a bootable system from it, and "
            + "write the machine's configuration. Copies about 37MB into Application "
            + "Support; nothing is downloaded and nothing leaves your machine."
        setUp.target = self
        setUp.action = #selector(setUpPressed)
        setUpButton = setUp

        let start = VBOptionButton(title: "START", onColour: Theme.Color.tallyOnAir)
        start.toolTip = "Start the machine. Its picture becomes available as a source."
        start.target = self
        start.action = #selector(startPressed)
        startButton = start

        let show = VBOptionButton(title: "OPEN")
        show.toolTip = "Bring the emulator's own window forward, to use the software "
            + "directly — loading a script, fixing a page, anything the faders below "
            + "do not cover."
        show.target = self
        show.action = #selector(showPressed)
        showButton = show

        // The state key, which changes ROLE rather than multiplying buttons. There is
        // one useful thing to do about save states at any moment, and which one it is
        // depends entirely on whether a state exists yet.
        let state = VBOptionButton(title: "SAVE STATE")
        state.target = self
        state.action = #selector(statePressed)
        stateButton = state

        let row = Controls.row([setUp, start, show, state, Controls.spacer()], spacing: 4)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// The two lines of the title, and the key that puts them on air.
    ///
    /// ── WHY THERE IS A TAKE AND THE FIELDS DO NOT SEND AS YOU TYPE ──────────────
    ///
    /// Because this reaches PROGRAM. A field that sent on every keystroke would put
    /// half-typed words on air, one letter at a time, in front of an audience. Every
    /// broadcast character generator ever built solves this the same way: type freely,
    /// then take. The fields commit on Return or when focus leaves them — that is
    /// AppKit's own behaviour for an NSTextField action and it is the right one here —
    /// and TAKE repaints the page from whatever the panel currently holds, which is
    /// also how you put a page back after the machine has been touched by hand.
    ///
    /// Everything else on this panel IS live, because a menu choice and a fader move
    /// are single deliberate gestures, not a stream of half-finished ones.
    private func buildTextRow() {
        let header = Controls.row([
            Controls.label("TEXT", font: Theme.Font.tinyLabel,
                           color: Theme.Color.textSecondary, holdsWidth: true),
            Controls.spacer()
        ], spacing: 4)
        addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        for line in 0..<2 {
            let field = NSTextField(string: line == 0
                ? controller.panel.state.text
                : controller.panel.state.textTwo)
            field.font = Theme.Font.label
            field.controlSize = .small
            field.placeholderString = line == 0 ? "Title" : "Second line (optional)"
            field.tag = line
            field.target = self
            field.action = #selector(textChanged(_:))
            field.toolTip = line == 0
                ? "The first line. Goes to the machine when you press Return or click "
                    + "away — not as you type, because this reaches PROGRAM."
                : "A second line, drawn below the first. Leave it empty for a one-line "
                    + "title; Scala is only sent a line that has something in it."
            field.translatesAutoresizingMaskIntoConstraints = false
            textFieldsByLine[line] = field

            let row = Controls.row([
                Controls.label(line == 0 ? "1" : "2", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                field
            ], spacing: 4)
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }

        let take = VBOptionButton(title: "TAKE", onColour: Theme.Color.tallyOnAir)
        take.target = self
        take.action = #selector(takePressed)
        take.toolTip = "Repaint the page on the machine from everything this panel "
            + "holds. Use it after typing, or to put the title back after the machine "
            + "has been touched by hand."
        takeButton = take

        let takeRow = Controls.row([Controls.spacer(), take], spacing: 4)
        addArrangedSubview(takeRow)
        takeRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// Draws the control set, grouped, with the widget each control asks for.
    ///
    /// The SHAPE comes from the control, not from here. Every one of these used to be a
    /// fader: choosing one of fifty-one wipes meant dragging until the readout happened
    /// to say the right word, and choosing a typeface meant the same. A list is a list.
    private func buildControls() {
        let groups = TitlerControlSet.groups(for: controller.program)
        guard !groups.isEmpty else {
            let note = Controls.label(
                TitlerControlSet.noPanelReason(for: controller.program) ?? "No controls.",
                font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            addArrangedSubview(note)
            return
        }

        for group in groups {
            addArrangedSubview(sectionHeader(group.title))
            for control in group.controls { addArrangedSubview(row(for: control)) }
        }

        for view in arrangedSubviews where view.identifier?.rawValue == Self.fullWidthRow {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    /// A quiet rule with a name on it, so the panel reads as sections rather than a
    /// list of thirty things.
    private func sectionHeader(_ title: String) -> NSView {
        let label = Controls.label(
            title, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        let row = Controls.row([label, Controls.spacer()], spacing: 4)
        row.identifier = NSUserInterfaceItemIdentifier(Self.fullWidthRow)
        return row
    }

    private static let fullWidthRow = "emu.row"

    /// One control: its name, its widget, and its current value in Scala's own units.
    private func row(for control: TitlerControl) -> NSView {
        let name = Controls.label(
            control.name, font: Theme.Font.tinyLabel,
            color: Theme.Color.textSecondary, holdsWidth: true)

        let inner: NSView
        switch control.shape {
        case .list:      inner = listWidget(for: control)
        case .toggle:    inner = toggleWidget(for: control)
        case .colour:    inner = colourWidget(for: control)
        case .continuous: inner = faderWidget(for: control)
        }
        inner.toolTip = control.explanation

        // A fader already carries its own slot and code. Everything else gets wrapped
        // so that Shift lights it too — the promise is that ONE gesture reveals every
        // control that can go under a knob, and that only holds if it reveals all of
        // them.
        let widget: NSView
        if control.shape == .continuous {
            widget = inner
        } else {
            widget = MappableControl(
                content: inner,
                slot: Engine.emulatorSlot,
                code: control.code,
                // A switch learns a KEY; a menu takes anything, because stepping a list
                // with a knob is the point of putting a knob on one.
                detectFilter: control.shape == .toggle ? .notesOnly : .anything)
            widget.toolTip = control.explanation
        }

        // The readout stays for the continuous controls, where a number is the only way
        // to know where you are. A menu already shows its own answer.
        var pieces: [NSView] = [name, widget]
        if control.shape == .continuous {
            let readout = Controls.label(
                controller.readout(for: control.function),
                font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            readout.alignment = .right
            readouts[control.function] = readout
            pieces = [name, widget, readout]
        }

        let row = Controls.row(pieces, spacing: 6)
        row.identifier = NSUserInterfaceItemIdentifier(Self.fullWidthRow)
        return row
    }

    private func listWidget(for control: TitlerControl) -> NSView {
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.controlSize = .small
        menu.font = Theme.Font.tinyLabel
        menu.target = self
        menu.action = #selector(listChanged(_:))
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.setContentHuggingPriority(.defaultLow, for: .horizontal)
        menus[control.function] = menu
        // A control's param code rides on the widget so a Shift-click can learn it,
        // exactly as it does for a fader. A menu under a MIDI knob steps through its
        // items, which is what a knob on a list should do.
        mappingByControl[ObjectIdentifier(menu)] = control.function
        return menu
    }

    private func toggleWidget(for control: TitlerControl) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        switches[control.function] = toggle
        mappingByControl[ObjectIdentifier(toggle)] = control.function
        let holder = Controls.row([toggle, Controls.spacer()], spacing: 0)
        return holder
    }

    private func colourWidget(for control: TitlerControl) -> NSView {
        let well = NSColorWell()
        well.isBordered = true
        well.target = self
        well.action = #selector(colourChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.heightAnchor.constraint(equalToConstant: 18).isActive = true
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        wells[control.function] = well
        mappingByControl[ObjectIdentifier(well)] = control.function
        let holder = Controls.row([well, Controls.spacer()], spacing: 0)
        return holder
    }

    private func faderWidget(for control: TitlerControl) -> NSView {
        let fader = Controls.fader(
            value: control.function == .colourCycle ? 0 : 0.5,
            compact: true,
            // SLOT AND CODE, which is what makes this fader exactly like every other
            // fader in the window: Shift-click learns it to a MIDI control, Cmd-Option
            // marks a sweep, an LFO or the beat clock can drive it, and a template
            // saves it. None of that machinery knows it is driving an emulator.
            mappingSlot: Engine.emulatorSlot,
            mappingCode: control.code,
            target: self, action: #selector(faderMoved(_:)))
        faders[control.function] = fader
        return fader
    }

    // MARK: - Actions

    @objc private func setUpPressed() {
        setUpButton?.isEnabled = false
        statusLabel.stringValue = "Setting up…"
        controller.setUp(
            progress: { [weak self] text in
                self?.statusLabel.stringValue = text
            },
            completion: { [weak self] error in
                self?.setUpButton?.isEnabled = true
                if let error {
                    self?.statusLabel.stringValue = error
                    self?.statusLabel.textColor = Theme.Color.tallyOnAir
                } else {
                    self?.statusLabel.textColor = Theme.Color.textSecondary
                }
                self?.refresh()
            })
    }

    @objc private func startPressed() {
        if controller.isRunning {
            controller.stop()
        } else if controller.start() {
            // A cold boot is ahead: Kickstart, then the Workbench startup, then Scala
            // itself. The panel says so instead of showing the emulator's blank window.
            screen.resetPictureState()
            // Send the whole panel once the machine is up, so the faders and the
            // machine agree from the start rather than from whichever one is moved
            // first.
            controller.synchronise()
        }
        refresh()
    }

    @objc private func showPressed() {
        controller.showMachine()
    }

    @objc private func statePressed() {
        guard controller.saveState.exists else {
            // Bring the machine forward first: the instructions are about things to do
            // in ITS window, and an alert in front of the wrong window is an alert
            // nobody can act on.
            controller.showMachine()

            let alert = NSAlert()
            alert.messageText = "Save the machine's state"
            alert.informativeText = EmulatorController.saveStateInstructions
            alert.addButton(withTitle: "OK")
            alert.runModal()
            refresh()
            return
        }

        // A state exists, so this key is a switch: does the next start restore it?
        controller.restoresSavedState.toggle()
        Log.info(.titler, "next start will "
            + (controller.restoresSavedState ? "restore the saved state" : "boot from cold"))
        refresh()
    }

    @objc private func textChanged(_ sender: NSTextField) {
        controller.setText(sender.stringValue, line: sender.tag)
    }

    /// Repaints the page on the machine from everything the panel holds.
    @objc private func takePressed() {
        controller.synchronise()
    }

    @objc private func listChanged(_ sender: NSPopUpButton) {
        guard let function = mappingByControl[ObjectIdentifier(sender)] else { return }
        controller.choose(function, option: sender.indexOfSelectedItem)
        // Choosing a face changes which SIZES exist, so that menu is rebuilt rather
        // than left showing sizes the new face does not have.
        if function == .fontFace { refreshList(.fontSize) }
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let function = mappingByControl[ObjectIdentifier(sender)] else { return }
        controller.move(function, to: sender.state == .on ? 1 : 0)
    }

    @objc private func colourChanged(_ sender: NSColorWell) {
        guard let function = mappingByControl[ObjectIdentifier(sender)] else { return }
        // Scala has one hue control per colour, so the well's hue is what reaches it.
        // The well is the honest widget to CHOOSE with; the 0...1 hue behind it is what
        // a MIDI knob or an LFO drives, and both end up in the same place.
        let colour = sender.color.usingColorSpace(.deviceRGB) ?? .white
        controller.move(function, to: Double(colour.hueComponent))
    }

    @objc private func faderMoved(_ sender: VBFader) {
        guard let function = faders.first(where: { $0.value === sender })?.key else { return }
        controller.move(function, to: sender.value)
        readouts[function]?.stringValue = controller.readout(for: function)
    }

    // MARK: - State

    /// Brings everything into line with the controller.
    func refresh() {
        statusLabel.stringValue = controller.summary

        // The screen follows the machine: pulling frames while it runs, stopped and
        // explaining itself when it does not.
        screen.host = controller.isRunning ? controller.host : nil
        screen.placeholder = controller.isSetUp
            ? (controller.isRunning
                ? "Booting the machine — Kickstart, Workbench, then Scala (~20s)"
                : "Press START")
            : "Press SET UP to build a machine"
        if controller.isRunning { screen.start() } else { screen.stop() }

        startButton?.isOn = controller.isRunning
        startButton?.setTitle(controller.isRunning ? "STOP" : "START")
        startButton?.isEnabled = controller.isSetUp
        showButton?.isEnabled = controller.isRunning

        // The state key's role: make one, or choose whether to use the one there is.
        let state = controller.saveState
        stateButton?.setTitle(state.exists ? "LOAD STATE" : "SAVE STATE")
        stateButton?.isOn = state.exists && controller.restoresSavedState
        stateButton?.isEnabled = controller.isSetUp
        stateButton?.toolTip = state.exists
            ? "\(state.summary). Lit means the next start restores it instead of "
                + "booting from cold — about a second rather than a minute."
            : "How to save the machine where you want it to start. One-time, and done "
                + "in the emulator's own window."
        linkDot.state = controller.linkState

        takeButton?.isEnabled = controller.isRunning

        // A control with nothing behind it greys and says why, rather than moving and
        // changing nothing. That matters most for the font size: until a drive has been
        // read there is no way to know which sizes are safe, and an unsafe one drops
        // Scala's screen.
        for (function, fader) in faders {
            let reason = controller.unavailableReason(for: function)
            fader.isEnabled = reason == nil
            if let reason { fader.toolTip = reason }
            readouts[function]?.stringValue = controller.readout(for: function)
        }
        for function in menus.keys { refreshList(function) }
        for (function, toggle) in switches {
            let reason = controller.unavailableReason(for: function)
            toggle.isEnabled = reason == nil
            if let reason { toggle.toolTip = reason }
            toggle.state = controller.panel.isOn(function) ? .on : .off
        }
        for (function, well) in wells {
            let reason = controller.unavailableReason(for: function)
            well.isEnabled = reason == nil
            if let reason { well.toolTip = reason }
            well.color = controller.panel.colour(for: function).map(Self.nsColour) ?? .white
        }

        for (line, field) in textFieldsByLine {
            let wanted = line == 0
                ? controller.panel.state.text
                : controller.panel.state.textTwo
            // Only when it differs, and never while it is being typed into: writing to a
            // field under the cursor moves the insertion point to the end mid-word.
            if field.stringValue != wanted, field.currentEditor() == nil {
                field.stringValue = wanted
            }
        }
    }

    /// Refills one menu from the panel, and greys it when there is nothing to choose.
    private func refreshList(_ function: TitlerFunction) {
        guard let menu = menus[function] else { return }
        let options = controller.panel.options(for: function)
        let reason = controller.unavailableReason(for: function)

        menu.removeAllItems()
        if options.isEmpty {
            // A menu with nothing in it still has to be a menu — an empty popup that
            // looks clickable and is not is worse than one that says what is missing.
            menu.addItem(withTitle: "—")
            menu.isEnabled = false
            menu.toolTip = reason ?? "Nothing to choose from yet"
            return
        }
        menu.addItems(withTitles: options)
        menu.selectItem(at: min(controller.panel.selectedOption(for: function),
                                options.count - 1))
        menu.isEnabled = reason == nil
        if let reason { menu.toolTip = reason }
    }

    /// An `NSColor` for a Scala colour, for the wells.
    private static func nsColour(_ colour: ScalaColour) -> NSColor {
        NSColor(deviceRed: CGFloat(colour.red), green: CGFloat(colour.green),
                blue: CGFloat(colour.blue), alpha: 1)
    }
}

/// The small lamp saying whether the machine is answering.
final class LinkIndicatorView: NSView {

    var state: AmigaLinkState = .idle {
        didSet {
            guard state != oldValue else { return }
            toolTip = "Command link: \(state.summary)"
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 10).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let colour: NSColor
        switch state {
        case .idle: colour = Theme.Color.textTertiary
        case .waiting: colour = Theme.Color.accent.withAlphaComponent(0.4)
        case .live: colour = Theme.Color.accent
        case .failed: colour = Theme.Color.tallyOnAir
        }
        colour.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

/// The machine's tile in the browser, which can be dragged onto a source.
///
/// Dragging is the gesture the rest of the library already uses, so the machine
/// behaves like an asset rather than like a special case — which is the point of it
/// being in the asset browser at all.
final class EmuMachineTile: NSView {

    /// Called when the tile is dropped on a source panel, with its channel letter.
    var onDroppedOnChannel: ((String) -> Void)?

    private let title: String
    private let subtitle: String

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 42).isActive = true
        toolTip = "\(subtitle) on \(title) — drag onto a source window to assign it, "
            + "or pick \"Amiga (EMU)\" in that source's menu."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard body.width > 2, body.height > 2 else { return }
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Theme.Metrics.buttonCornerRadius,
            yRadius: Theme.Metrics.buttonCornerRadius)
        Theme.Color.panelFillNested.setFill()
        path.fill()
        Theme.Color.panelBorder.setStroke()
        path.lineWidth = Theme.Metrics.hairline
        path.stroke()

        // A machine, drawn rather than lettered: a squat box with a screen, which is
        // what an A1200 with a monitor on it looks like from across a room.
        let screen = NSRect(
            x: body.minX + 8, y: body.minY + 14, width: body.width - 16, height: body.height - 22)
        Theme.Color.accent.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2).fill()
        Theme.Color.accent.setStroke()
        let outline = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()

        let keyboard = NSRect(
            x: body.minX + 5, y: body.minY + 5, width: body.width - 10, height: 6)
        Theme.Color.textTertiary.setFill()
        NSBezierPath(roundedRect: keyboard, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        // A file promise would be wrong — there is no file. The drag carries the
        // machine's identity as text, and the source panels already accept a drop.
        let item = NSDraggingItem(pasteboardWriter: Engine.emulatorSlot as NSString)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        return image
    }
}

extension EmuMachineTile: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
