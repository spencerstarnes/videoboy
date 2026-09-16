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
//  Extend  : do not add anything here that is not transport or clock.
//

import AppKit
import VideoboyCore

/// The transport/clock toolbar.
final class TransportToolbarView: NSView {

    private let playButton: NSButton

    /// Called when Tap is pressed.
    var onTap: (() -> Void)?
    /// Called when play/stop is toggled, with the new running state.
    var onPlayToggled: ((Bool) -> Void)?
    /// Called when the subdivision popup changes, with the chosen label.
    var onSubdivisionChanged: ((String) -> Void)?

    private var isRunning = false
    /// The recessed cluster: tempo, clock and subdivision.
    let display = TransportDisplayView(frame: .zero)
    private var clockSourceName = "Internal"
    private var subdivisionName = "1/4"

    /// Which codec recordings use.
    private var codecPopUp: NSPopUpButton?

    /// The codec currently chosen in the Record group.
    var selectedRecordCodec: FrameRecorder.Codec {
        guard let title = codecPopUp?.titleOfSelectedItem,
              let codec = FrameRecorder.Codec(rawValue: title) else { return .proRes422 }
        return codec
    }

    @objc private func recordCodecChanged(_ sender: NSPopUpButton) {
        Log.info(.app, "recording codec is now \(sender.titleOfSelectedItem ?? "?")")
    }

    /// The record button, top right.
    let recordButton = RecordButton(frame: .zero)

    /// Which panel groups are shown.
    private let panelsControl = NSSegmentedControl()

    /// The Shift-to-detect reminder, which lights while Shift is held.
    private let detectButton = Controls.button("⇧ Learn")

    /// Called when the Learn reminder is clicked, to explain the gesture.
    var onDetectExplainRequested: (() -> Void)?

    /// Called when a panel group is shown or hidden.
    var onPanelGroupToggled: ((PanelGroup, Bool) -> Void)?

    /// Called when record is pressed, with the new recording state.
    var onRecordToggled: ((Bool) -> Void)?

    /// Called when the clock source changes. The app answers false if it could not
    /// switch, and the popup snaps back.
    var onClockSourceChanged: ((String) -> Bool)?

    /// Lights the Learn reminder while Shift is held, so the key and the highlighted
    /// controls are visibly the same thing.
    func setDetectArmed(_ armed: Bool) {
        detectButton.contentTintColor = armed ? Theme.Color.detectHighlight : nil
    }

    @objc private func detectPressed() {
        onDetectExplainRequested?()
    }

    override init(frame frameRect: NSRect) {
        playButton = Controls.button("▶")
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.bar.cgColor

        playButton.target = self
        playButton.action = #selector(playPressed)

        let tapButton = Controls.button("Tap", target: self, action: #selector(tapPressed))


        // Shift-to-detect (SPEC 7): held Shift highlights mappable controls.
        // A reminder of the gesture rather than a button that starts a mode — there
        // is no mode to start, which is the nice thing about it. It lights with the
        // controls so the connection between the key and the highlights is stated
        // rather than left to be inferred.
        detectButton.target = self
        detectButton.action = #selector(detectPressed)
        detectButton.toolTip = "Hold Shift to see every mappable control, then click one to map it"

        // Record, top right. The codec and stream selection sit beside the button so
        // the whole recording decision is in one place.
        // ProRes only, because that is what AVAssetWriter encodes here and what a
        // capture meant for editing wants. DV was on this list before anything could
        // record at all; offering it now would be offering something that does not
        // happen.
        let codecPopUp = Controls.popUp(
            FrameRecorder.Codec.allCases.map(\.rawValue),
            target: self, action: #selector(recordCodecChanged(_:)))
        self.codecPopUp = codecPopUp
        // What is recorded is whatever is ARMED, chosen by the dots on the previews,
        // so a second control naming a fixed combination would only disagree with
        // them. It stays as a readout of what arming currently means.
        let streamsPopUp = Controls.popUp(["Armed feeds"], enabled: false)
        streamsPopUp.toolTip = "Recording follows the arming dots on each preview"
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        // Enabled even though the encoder is not built: arming and the
        // transport-locked indicators are real and worth using, and pressing record
        // says plainly what is missing rather than being inert with no explanation.
        recordButton.isEnabled = true

        let recordGroup = Controls.row([
            group("Record", Controls.row([codecPopUp, streamsPopUp], spacing: 4)),
            recordButton
        ], spacing: 8)

        // Panel show/hide, Resolve-style. A multi-select segmented control: each
        // segment is a group, selected means shown. One control rather than four
        // buttons, because they are one decision about how much of the window you
        // want given over to edges.
        panelsControl.segmentCount = PanelGroup.allCases.count
        panelsControl.trackingMode = .selectAny
        panelsControl.controlSize = .small
        panelsControl.font = Theme.Font.tinyLabel
        panelsControl.target = self
        panelsControl.action = #selector(panelsChanged(_:))
        for (index, panelGroup) in PanelGroup.allCases.enumerated() {
            panelsControl.setLabel(panelGroup.displayName, forSegment: index)
            panelsControl.setSelected(true, forSegment: index)
            panelsControl.setToolTip("Show or hide \(panelGroup.longName)", forSegment: index)
        }

        // The cluster is CENTRED, with panels on the left and record on the right.
        // Tempo and clock are what a performer glances at constantly, so they belong
        // in the middle of the window rather than tucked into a corner of a toolbar.
        display.onClockSourceCycled = { [weak self] in self?.cycleClockSource() }
        display.onSubdivisionCycled = { [weak self] in self?.cycleSubdivision() }
        display.translatesAutoresizingMaskIntoConstraints = false

        let leftGroup = Controls.row([
            group("Panels", panelsControl),
            tapButton,
            playButton
        ], spacing: 10)

        let rightGroup = Controls.row([
            group("Detect", detectButton),
            separator(),
            recordGroup
        ], spacing: 10)

        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        rightGroup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftGroup)
        addSubview(display)
        addSubview(rightGroup)

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
                greaterThanOrEqualTo: display.trailingAnchor, constant: 12)
        ])
    }

    /// Advances the clock source, reporting back if the app refuses the change.
    private func cycleClockSource() {
        let sources = ["Internal", "Audio", "MIDI Clock", "Link"]
        let currentIndex = sources.firstIndex(of: clockSourceName) ?? 0
        let next = sources[(currentIndex + 1) % sources.count]
        if onClockSourceChanged?(next) == true {
            clockSourceName = next
            display.setClockSource(next)
        }
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
    func setBeat(_ beatInBar: Int) {
        display.setBeat(beatInBar)
    }

    /// Updates the running indicator.
    func setRunning(_ running: Bool) {
        isRunning = running
        playButton.title = running ? "■" : "▶"
        display.setSyncStatus(running ? "running" : "stopped")
    }

    // MARK: - Actions

    @objc private func playPressed() {
        setRunning(!isRunning)
        onPlayToggled?(isRunning)
    }

    @objc private func tapPressed() { onTap?() }

    @objc private func panelsChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < PanelGroup.allCases.count else { return }
        let panelGroup = PanelGroup.allCases[index]
        onPanelGroupToggled?(panelGroup, !sender.isSelected(forSegment: index))
    }

    /// Reflects a collapse that happened elsewhere — clicking a rail, for instance.
    func setPanelGroupShown(_ panelGroup: PanelGroup, _ shown: Bool) {
        guard let index = PanelGroup.allCases.firstIndex(of: panelGroup) else { return }
        panelsControl.setSelected(shown, forSegment: index)
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
}
