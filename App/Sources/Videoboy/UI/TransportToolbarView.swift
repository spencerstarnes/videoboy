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

    private let tempoLabel = Controls.label("120.0", font: Theme.Font.tempo, color: Theme.Color.textPrimary)
    private let playButton: NSButton
    private let beatLights: [NSView]
    private let syncLabel = Controls.monoLabel("stopped", color: Theme.Color.textSecondary)

    /// Called when Tap is pressed.
    var onTap: (() -> Void)?
    /// Called when play/stop is toggled, with the new running state.
    var onPlayToggled: ((Bool) -> Void)?
    /// Called when the subdivision popup changes, with the chosen label.
    var onSubdivisionChanged: ((String) -> Void)?

    private var isRunning = false
    private var clockSourcePopUp: NSPopUpButton?

    /// The record button, top right.
    let recordButton = RecordButton(frame: .zero)

    /// Which panel groups are shown.
    private let panelsControl = NSSegmentedControl()

    /// Called when a panel group is shown or hidden.
    var onPanelGroupToggled: ((PanelGroup, Bool) -> Void)?

    /// Called when record is pressed, with the new recording state.
    var onRecordToggled: ((Bool) -> Void)?

    /// Called when the clock source changes. The app answers false if it could not
    /// switch, and the popup snaps back.
    var onClockSourceChanged: ((String) -> Bool)?

    override init(frame frameRect: NSRect) {
        // Four beat lights, one per beat of a 4/4 bar, as in the mockup.
        beatLights = (0..<4).map { _ in
            let light = NSView()
            light.wantsLayer = true
            light.layer?.cornerRadius = 2
            light.layer?.backgroundColor = Theme.Color.textTertiary.cgColor
            light.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                light.widthAnchor.constraint(equalToConstant: 9),
                light.heightAnchor.constraint(equalToConstant: 9)
            ])
            return light
        }
        playButton = Controls.button("▶")
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.bar.cgColor

        playButton.target = self
        playButton.action = #selector(playPressed)

        let tapButton = Controls.button("Tap", target: self, action: #selector(tapPressed))

        let beats = Controls.row(beatLights, spacing: 3)
        // Internal and audio detection work; MIDI clock and Link are later work
        // (SPEC 4b), so they are present and selectable but report unavailable.
        let clockSource = Controls.popUp(
            ["Internal", "Audio", "MIDI Clock", "Link"],
            target: self, action: #selector(clockSourceChanged(_:)))
        self.clockSourcePopUp = clockSource
        let subdivision = Controls.popUp(
            ["1/1", "1/2", "1/4", "1/8", "1/16"], target: self, action: #selector(subdivisionChanged(_:))
        )
        subdivision.selectItem(withTitle: "1/4")

        // Shift-to-detect (SPEC 7): held Shift highlights mappable controls.
        let detect = Controls.button("⇧ Learn", enabled: false)

        // Record, top right. The codec and stream selection sit beside the button so
        // the whole recording decision is in one place.
        let codecPopUp = Controls.popUp(["ProRes 422", "ProRes HQ", "DV"], enabled: false)
        let streamsPopUp = Controls.popUp(["PRIMARY", "PRI + A/B/C/D"], enabled: false)
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

        let row = Controls.row([
            group("Panels", panelsControl),
            separator(),
            group("Tempo", tempoLabel),
            tapButton,
            playButton,
            group("Phase", beats),
            group("Clock", clockSource),
            group("Sync", syncLabel),
            group("Subdiv", subdivision),
            Controls.spacer(),
            group("Detect", detect),
            separator(),
            recordGroup
        ], spacing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
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
        let heading = Controls.label(caption, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        let column = Controls.column([heading, control], spacing: 2)
        column.alignment = .leading
        return column
    }

    // MARK: - State from the transport

    /// Updates the tempo readout.
    func setTempo(_ beatsPerMinute: Double) {
        tempoLabel.stringValue = String(format: "%.1f", beatsPerMinute)
    }

    /// Lights the beat corresponding to the current position in the bar.
    func setBeat(_ beatInBar: Int) {
        for (index, light) in beatLights.enumerated() {
            light.layer?.backgroundColor = (index == beatInBar)
                ? Theme.Color.accent.cgColor
                : Theme.Color.textTertiary.cgColor
        }
    }

    /// Updates the running indicator.
    func setRunning(_ running: Bool) {
        isRunning = running
        playButton.title = running ? "■" : "▶"
        syncLabel.stringValue = running ? "running" : "stopped"
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

    @objc private func subdivisionChanged(_ sender: NSPopUpButton) {
        onSubdivisionChanged?(sender.titleOfSelectedItem ?? "1/4")
    }

    @objc private func clockSourceChanged(_ sender: NSPopUpButton) {
        let choice = sender.titleOfSelectedItem ?? "Internal"
        // Snapping back on failure matters: a popup reading "Audio" with no audio
        // behind it is a lie the performer would only discover mid-set.
        if onClockSourceChanged?(choice) == false {
            sender.selectItem(withTitle: "Internal")
        }
    }

    /// Updates the sync readout with what the clock is actually doing.
    func setSyncStatus(_ text: String) {
        syncLabel.stringValue = text
    }
}
