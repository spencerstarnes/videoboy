//
//  TransportToolbarView.swift — the unified toolbar above the grid.
//
//  Purpose : SPEC 14.1 is explicit that this toolbar holds *only* transport and
//            clock: tempo, tap, play, phase, clock source, sync, subdivision, and
//            the detect/learn button. Record and output live in the bottom bar.
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
        // Clock source: only the internal transport exists so far; audio detection,
        // MIDI clock and Link are later work (SPEC 4b).
        let clockSource = Controls.popUp(["Internal", "Audio", "MIDI Clock", "Link"], enabled: false)
        let subdivision = Controls.popUp(
            ["1/1", "1/2", "1/4", "1/8", "1/16"], target: self, action: #selector(subdivisionChanged(_:))
        )
        subdivision.selectItem(withTitle: "1/4")

        // Shift-to-detect (SPEC 7): held Shift highlights mappable controls.
        let detect = Controls.button("⇧ Learn", enabled: false)

        let row = Controls.row([
            group("Tempo", tempoLabel),
            tapButton,
            playButton,
            group("Phase", beats),
            group("Clock", clockSource),
            group("Sync", syncLabel),
            group("Subdiv", subdivision),
            Controls.spacer(),
            group("Detect", detect)
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

    @objc private func subdivisionChanged(_ sender: NSPopUpButton) {
        onSubdivisionChanged?(sender.titleOfSelectedItem ?? "1/4")
    }
}
