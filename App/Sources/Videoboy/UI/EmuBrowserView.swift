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
    private let linkDot = LinkIndicatorView()

    private var faders: [TitlerFunction: VBFader] = [:]
    private var readouts: [TitlerFunction: NSTextField] = [:]
    private var textField: NSTextField?

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

        let row = Controls.row([setUp, start, show, Controls.spacer()], spacing: 4)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func buildTextRow() {
        let field = NSTextField(string: controller.panel.state.text)
        field.font = Theme.Font.label
        field.controlSize = .small
        field.placeholderString = "Title text"
        field.target = self
        field.action = #selector(textChanged(_:))
        field.toolTip = "The line of text on screen. Sent as a TEXT command the moment "
            + "you press Return."
        field.translatesAutoresizingMaskIntoConstraints = false
        textField = field

        let row = Controls.row([
            Controls.label("TEXT", font: Theme.Font.tinyLabel,
                           color: Theme.Color.textTertiary, holdsWidth: true),
            field
        ], spacing: 4)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func buildControls() {
        let controls = TitlerControlSet.controls(for: controller.program)
        guard !controls.isEmpty else {
            let note = Controls.label(
                TitlerControlSet.noPanelReason(for: controller.program) ?? "No controls.",
                font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            addArrangedSubview(note)
            return
        }

        for control in controls {
            // Two lines per control, the same shape an effect parameter uses, so a
            // fader here behaves and reads exactly like a fader anywhere else in the
            // window.
            let name = Controls.label(
                control.name, font: Theme.Font.tinyLabel,
                color: Theme.Color.textSecondary, holdsWidth: true)
            let readout = Controls.label(
                controller.readout(for: control.function),
                font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            readout.alignment = .right
            readouts[control.function] = readout

            let header = Controls.row([name, Controls.spacer(), readout], spacing: 4)
            addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

            let fader = Controls.fader(
                value: control.function == .colourCycle ? 0 : 0.5,
                compact: true,
                mappingSlot: Engine.emulatorSlot,
                target: self, action: #selector(faderMoved(_:)))
            // The tooltip explains what it does TO THE SOFTWARE, which is the whole
            // point of the control set — a slider labelled SCALE that cannot say what
            // it scales is a slider nobody trusts.
            fader.toolTip = control.explanation
            faders[control.function] = fader
            addArrangedSubview(fader)
            fader.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
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

    @objc private func textChanged(_ sender: NSTextField) {
        controller.setText(sender.stringValue)
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
        startButton?.isOn = controller.isRunning
        startButton?.setTitle(controller.isRunning ? "STOP" : "START")
        startButton?.isEnabled = controller.isSetUp
        showButton?.isEnabled = controller.isRunning
        linkDot.state = controller.linkState

        // A control with nothing behind it greys and says why, rather than moving and
        // changing nothing.
        for (function, fader) in faders {
            let reason = controller.unavailableReason(for: function)
            fader.isEnabled = reason == nil
            if let reason { fader.toolTip = reason }
            readouts[function]?.stringValue = controller.readout(for: function)
        }
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
