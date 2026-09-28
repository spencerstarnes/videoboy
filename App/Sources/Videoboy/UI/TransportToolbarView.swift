//
//  TransportToolbarView.swift — the unified toolbar above the grid.
//
//  Purpose : Transport and clock on the left — tempo, tap, play, phase, clock source,
//            sync, subdivision — and the record controls on the right.
//
//            SPEC 14.1 originally said this toolbar held transport and clock ONLY,
//            with record in the bottom bar. That was changed on the owner's
//            instruction: record is the one control that has to be hit without
//            hunting for it and read from across a room, and the bottom bar is
//            neither. SPEC 14 has been updated to match rather than left in conflict.
//  Inputs  : transport state pushed in by the app.
//  Outputs : user intent, via its callbacks.
//  Connects: Core's Transport (BPM, phase) and DetectSession (shift-to-detect).
//            The Clip Pads (docs/specs/clip-pads.md) flank the cluster, 1–4 left and
//            5–8 right, in what was empty bar — also the owner's instruction
//            (2026-09-28): launching clips on the beat is a transport concern.
//  Extend  : do not add anything here that is not transport, clock or the pads. The
//            pads must never move anything else in the bar: they hang off the
//            cluster's sides and simply hide when a window is too narrow for them.
//

import AppKit
import VideoboyCore

/// The transport/clock toolbar.
final class TransportToolbarView: NSView {

    /// Play, as a proper transport key rather than a push button.
    private let playKey = VBTransportButton(glyph: "▶")

    /// Called when Tap is pressed.
    var onTap: (() -> Void)?
    /// Called when play/stop is toggled, with the new running state.
    var onPlayToggled: ((Bool) -> Void)?
    /// Called when the subdivision popup changes, with the chosen label.
    var onSubdivisionChanged: ((String) -> Void)?

    private var isRunning = false
    /// The recessed cluster: tempo, clock and subdivision.
    let display = TransportDisplayView(frame: .zero)
    private var subdivisionName = "1/4"

    /// The codec currently chosen, read off the cluster's format field.
    var selectedRecordCodec: FrameRecorder.Codec {
        FrameRecorder.Codec(rawValue: display.formatField.value) ?? .proRes422
    }

    /// Advances the recording format. Three choices cycle; they do not need a menu.
    private func cycleRecordFormat() {
        let all = FrameRecorder.Codec.allCases
        let index = all.firstIndex(where: { $0.rawValue == display.formatField.value }) ?? 0
        let next = all[(index + 1) % all.count]
        display.formatField.value = next.rawValue
        Log.info(.app, "recording format is now \(next.rawValue)")
    }

    /// The Clip Pads either side of the cluster. ClipPadController drives them.
    let leftPads = ClipPadStrip(side: .left)
    let rightPads = ClipPadStrip(side: .right)
    private var leftGroupView: NSView?
    private var rightGroupView: NSView?

    /// The record key, which lives in the centre cluster with the transport.
    let recordButton = RecordButton(frame: .zero)

    /// Which panel groups are shown, split by the side they are on.
    private let panelsLeftControl = NSSegmentedControl()
    private let panelsRightControl = NSSegmentedControl()

    /// The groups down each edge, in the order they appear top to bottom.
    private static let leftGroups: [PanelGroup] = [.sourcesLeft, .effectsLeft]
    private static let rightGroups: [PanelGroup] = [.sourcesRight, .effectsRight]

    /// Sets up one side's control.
    private func configure(
        _ control: NSSegmentedControl, groups: [PanelGroup], action: Selector
    ) {
        control.segmentCount = groups.count
        control.trackingMode = .selectAny
        control.controlSize = .small
        control.font = Theme.Font.tinyLabel
        control.target = self
        control.action = action
        for (index, panelGroup) in groups.enumerated() {
            control.setLabel(panelGroup.displayName, forSegment: index)
            control.setSelected(true, forSegment: index)
            control.setToolTip("Show or hide \(panelGroup.longName)", forSegment: index)
        }
    }

    /// The Shift-to-detect reminder, which lights while Shift is held.
    private let detectButton = Controls.button("⇧ Learn")

    /// Called when the Learn reminder is clicked, to explain the gesture.
    var onDetectExplainRequested: (() -> Void)?

    /// Called when a panel group is shown or hidden.
    var onPanelGroupToggled: ((PanelGroup, Bool) -> Void)?

    /// Called when record is pressed, with the new recording state.
    var onRecordToggled: ((Bool) -> Void)?

    /// Called when the CLOCK field is clicked, with the view to anchor a menu on.
    /// The app builds the menu: its choices (running apps) are only known there.
    var onClockMenuRequested: ((NSView) -> Void)?

    /// Lights the Learn reminder while Shift is held, so the key and the highlighted
    /// controls are visibly the same thing.
    func setDetectArmed(_ armed: Bool) {
        detectButton.contentTintColor = armed ? Theme.Color.detectHighlight : nil
    }

    @objc private func detectPressed() {
        onDetectExplainRequested?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.bar.cgColor



        // Shift-to-detect (SPEC 7): held Shift highlights mappable controls.
        // A reminder of the gesture rather than a button that starts a mode — there
        // is no mode to start, which is the nice thing about it. It lights with the
        // controls so the connection between the key and the highlights is stated
        // rather than left to be inferred.
        detectButton.target = self
        detectButton.action = #selector(detectPressed)
        detectButton.toolTip = "Hold Shift to see every mappable control, then click one to map it"

        // Record is a key in the cluster now, not a corner button with two popups
        // beside it. Arming is per-preview, so a popup naming a fixed combination of
        // feeds could only disagree with the dots that actually decide.
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        recordButton.isEnabled = true

        // Panel show/hide, Resolve-style. A multi-select segmented control: each
        // segment is a group, selected means shown. One control rather than four
        // buttons, because they are one decision about how much of the window you
        // want given over to edges.
        // One control per side, each sitting on the side it controls. A single
        // four-segment control in the corner meant the button for the right-hand FX
        // column was on the far left, so you had to read it rather than reach for it.
        configure(panelsLeftControl, groups: Self.leftGroups, action: #selector(leftPanelsChanged(_:)))
        configure(panelsRightControl, groups: Self.rightGroups, action: #selector(rightPanelsChanged(_:)))

        // The cluster is CENTRED, with panels on the left and record on the right.
        // Tempo and clock are what a performer glances at constantly, so they belong
        // in the middle of the window rather than tucked into a corner of a toolbar.
        display.onClockSourceClicked = { [weak self] in
            guard let self else { return }
            self.onClockMenuRequested?(self.display.clockSourceAnchor)
        }
        display.onSubdivisionCycled = { [weak self] in self?.cycleSubdivision() }
        display.onTap = { [weak self] in self?.onTap?() }
        display.translatesAutoresizingMaskIntoConstraints = false

        // Play is the same key as record now: the two controls that start and stop
        // everything look like each other and like nothing else in the window.
        playKey.target = self
        playKey.action = #selector(playPressed)
        playKey.toolTip = "Play or stop the transport"

        // The bar radiates from the middle. Panel buttons sit at both edges, the same
        // distance from their side and from the centre — they were flipped before,
        // with the control for the RIGHT-hand column over on the left. Everything
        // that runs a performance moved into the cluster in the middle.
        display.setTransportKeys([recordButton, playKey])
        display.formatField.onClick = { [weak self] in self?.cycleRecordFormat() }

        let leftGroup = Controls.row([
            group("Panels", panelsLeftControl)
        ], spacing: 10)

        let rightGroup = Controls.row([
            group("Detect", detectButton),
            separator(),
            group("Panels", panelsRightControl)
        ], spacing: 10)

        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        rightGroup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftGroup)
        addSubview(display)
        addSubview(rightGroup)
        addSubview(leftPads)
        addSubview(rightPads)
        leftGroupView = leftGroup
        rightGroupView = rightGroup

        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            display.centerXAnchor.constraint(equalTo: centerXAnchor),
            display.centerYAnchor.constraint(equalTo: centerYAnchor),
            display.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftGroup.trailingAnchor, constant: 12),

            rightGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightGroup.leadingAnchor.constraint(
                greaterThanOrEqualTo: display.trailingAnchor, constant: 12),

            // The pads hang off the cluster and constrain nothing else, so they can
            // never push a control that was already here.
            leftPads.trailingAnchor.constraint(equalTo: display.leadingAnchor, constant: -Self.padGap),
            leftPads.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightPads.leadingAnchor.constraint(equalTo: display.trailingAnchor, constant: Self.padGap),
            rightPads.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Between the cluster and the pads, and the least between the pads and the
    /// edge groups before the pads give way.
    private static let padGap: CGFloat = 16

    /// Hides both pad strips (never one — the bar stays symmetrical) when either
    /// would crowd its edge group in a narrow window.
    override func layout() {
        super.layout()
        guard let leftGroupView, let rightGroupView else { return }
        let fits = leftPads.frame.minX >= leftGroupView.frame.maxX + Self.padGap
            && rightPads.frame.maxX <= rightGroupView.frame.minX - Self.padGap
        if leftPads.isHidden == fits {
            leftPads.isHidden = !fits
            rightPads.isHidden = !fits
        }
    }

    /// Shows the clock source the app settled on.
    func setClockSource(_ name: String) {
        display.setClockSource(name)
    }

    /// Advances the subdivision.
    private func cycleSubdivision() {
        let all = Subdivision.allCases
        let currentIndex = all.firstIndex(where: { $0.rawValue == subdivisionName }) ?? 0
        let next = all[(currentIndex + 1) % all.count]
        subdivisionName = next.rawValue
        display.setSubdivision(next.rawValue)
        onSubdivisionChanged?(next.rawValue)
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// A vertical hairline, used to separate the transport from the record controls.
    ///
    /// A rule rather than more empty space: the two groups are different concerns and
    /// should read that way, but spreading them apart would waste the width.
    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.separator.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: Theme.Metrics.hairline),
            line.heightAnchor.constraint(equalToConstant: 26)
        ])
        return line
    }

    /// A caption above its control, as the mockup groups them.
    private func group(_ caption: String, _ control: NSView) -> NSStackView {
        // A caption that truncates stops naming its control, which is the only job
        // it has. Whatever else in the row has to give, it is not this.
        let heading = Controls.label(
            caption, font: Theme.Font.tinyLabel,
            color: Theme.Color.textTertiary, holdsWidth: true)
        let column = Controls.column([heading, control], spacing: 2)
        column.alignment = .leading
        return column
    }

    // MARK: - State from the transport

    /// Updates the tempo readout.
    func setTempo(_ beatsPerMinute: Double) {
        display.setTempo(beatsPerMinute)
    }

    /// Lights the beat corresponding to the current position in the bar.
    /// Feeds the tempo readout the beat phase, for its pulse.
    func setBeatPhase(_ phase: Double, isRunning: Bool) {
        display.setBeat(phase: phase, isRunning: isRunning)
    }

    func setBeat(_ beatInBar: Int) {
        display.setBeat(beatInBar)
    }

    /// Updates the running indicator.
    func setRunning(_ running: Bool) {
        isRunning = running
        playKey.glyph = running ? "■" : "▶"
        playKey.isActive = running
        display.setSyncStatus(running ? "running" : "stopped")
    }

    // MARK: - Actions

    @objc private func playPressed() {
        setRunning(!isRunning)
        onPlayToggled?(isRunning)
    }

    @objc private func tapPressed() { onTap?() }

    @objc private func leftPanelsChanged(_ sender: NSSegmentedControl) {
        panelsChanged(sender, groups: Self.leftGroups)
    }

    @objc private func rightPanelsChanged(_ sender: NSSegmentedControl) {
        panelsChanged(sender, groups: Self.rightGroups)
    }

    private func panelsChanged(_ sender: NSSegmentedControl, groups: [PanelGroup]) {
        let index = sender.selectedSegment
        guard index >= 0, index < groups.count else { return }
        onPanelGroupToggled?(groups[index], !sender.isSelected(forSegment: index))
    }

    /// Reflects a collapse that happened elsewhere — clicking a rail, for instance.
    func setPanelGroupShown(_ panelGroup: PanelGroup, _ shown: Bool) {
        if let index = Self.leftGroups.firstIndex(of: panelGroup) {
            panelsLeftControl.setSelected(shown, forSegment: index)
        } else if let index = Self.rightGroups.firstIndex(of: panelGroup) {
            panelsRightControl.setSelected(shown, forSegment: index)
        }
    }

    @objc private func recordPressed() {
        recordButton.isRecording.toggle()
        Log.info(.app, "record \(recordButton.isRecording ? "started" : "stopped")")
        onRecordToggled?(recordButton.isRecording)
    }





    /// Updates the sync readout with what the clock is actually doing.
    func setSyncStatus(_ text: String) {
        display.setSyncStatus(text)
    }

    func setSyncStatus(_ status: SyncStatus) {
        display.setSyncStatus(status)
    }

    /// Acknowledges a tempo that beat detection just locked onto.
    func flashDetectedTempo() {
        display.flashDetectedTempo()
    }
}
