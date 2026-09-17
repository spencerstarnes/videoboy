//
//  StatusBarView.swift — the status strip under the grid.
//
//  Purpose : SPEC 14.1's status bar: MIDI, OSC, node count, dropped frames and fps,
//            plus the fixed routing reminder on the right.
//  Inputs  : values pushed in by the app each second.
//  Outputs : text.
//  Connects: MIDIInput (device name), RenderLoop (fps and drops), the graph (nodes).
//  Extend  : add a field by adding a label here and a setter for it.
//

import AppKit
import VideoboyCore

/// The bottom status bar.
final class StatusBarView: NSView {

    private let midiLabel = Controls.monoLabel("MIDI: none")
    private let oscLabel = Controls.monoLabel("OSC: off")
    private let nodesLabel = Controls.monoLabel("0 nodes")
    private let rateLabel = Controls.monoLabel("drop 0 · 0.00")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.bar.cgColor

        // The routing reminder is fixed text: A/B always feed ONE and C/D always
        // feed TWO, and that never remaps (SPEC 2).
        let routing = Controls.label(
            "A/B → A/B Sub Mix · C/D → C/D Sub Mix · both → Program",
            font: Theme.Font.mono, color: Theme.Color.textTertiary
        )

        let row = Controls.row(
            [midiLabel, oscLabel, nodesLabel, rateLabel, Controls.spacer(), routing],
            spacing: 14
        )
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

    /// Shows the connected MIDI source, or "none".
    func setMIDIDevice(_ name: String?) {
        midiLabel.stringValue = "MIDI: \(name ?? "none")"
    }

    /// Shows the live node count of the render graph.
    func setNodeCount(_ count: Int) {
        nodesLabel.stringValue = "\(count) nodes"
    }

    /// Shows dropped frames and the measured render rate.
    func setRate(droppedFrames: Int, framesPerSecond: Double) {
        rateLabel.stringValue = String(format: "drop %d · %.2f", droppedFrames, framesPerSecond)
    }
}
