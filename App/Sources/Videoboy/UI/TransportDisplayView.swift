//
//  TransportDisplayView.swift — the transport cluster, Logic-style.
//
//  Purpose : Tempo and clock belong together in one recessed readout, not spread
//            across the toolbar as separate widgets. This is that cluster: a dark
//            inset panel with the tempo large, and the clock settings beside it as
//            TEXT YOU CLICK rather than popup menus.
//  Inputs   : transport state pushed in each frame.
//  Outputs  : callbacks when a setting is cycled.
//  Connects : TransportToolbarView hosts it; ShellController drives it.
//
//  Why not popups: a popup for four choices costs a click to open, a read, a click
//  to choose, and it covers the thing it belongs to while open. A field that cycles
//  on click costs one click and never occludes anything. Popups earn their place
//  when a list is long enough to need scanning — these are not.
//

import AppKit
import VideoboyCore

/// The recessed tempo and clock readout.
final class TransportDisplayView: NSView {

    /// Called when the clock source field is clicked, to advance it.
    var onClockSourceCycled: (() -> Void)?
    /// Called when the subdivision field is clicked, to advance it.
    var onSubdivisionCycled: (() -> Void)?
    /// Called when the tempo is edited directly.
    var onTempoEdited: ((Double) -> Void)?

    private let tempoField = NSTextField(labelWithString: "120.0")
    private let clockField = CyclingField(caption: "CLOCK", value: "Internal")
    private let subdivisionField = CyclingField(caption: "DIV", value: "1/4")
    private let syncLabel = NSTextField(labelWithString: "stopped")
    private var beatLights: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.Color.displayBackground.cgColor
        layer?.borderWidth = Theme.Metrics.hairline
        layer?.borderColor = Theme.Color.displayBorder.cgColor

        // Tempo, large and monospaced-digit so it does not jitter as it changes.
        tempoField.font = Theme.Font.tempo
        tempoField.textColor = Theme.Color.displayText
        tempoField.isSelectable = false

        let tempoUnit = NSTextField(labelWithString: "BPM")
        tempoUnit.font = Theme.Font.tinyLabel
        tempoUnit.textColor = Theme.Color.displayDimText

        beatLights = (0..<4).map { _ in
            let light = NSView()
            light.wantsLayer = true
            light.layer?.cornerRadius = 1.5
            light.layer?.backgroundColor = Theme.Color.displayDimText.withAlphaComponent(0.3).cgColor
            light.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                light.widthAnchor.constraint(equalToConstant: 8),
                light.heightAnchor.constraint(equalToConstant: 3)
            ])
            return light
        }

        syncLabel.font = Theme.Font.tinyLabel
        syncLabel.textColor = Theme.Color.displayDimText

        clockField.onClick = { [weak self] in self?.onClockSourceCycled?() }
        subdivisionField.onClick = { [weak self] in self?.onSubdivisionCycled?() }

        let tempoColumn = Controls.column([
            Controls.row([tempoField, tempoUnit], spacing: 4),
            Controls.row(beatLights, spacing: 3)
        ], spacing: 3)

        let settingsColumn = Controls.column([clockField, subdivisionField], spacing: 2)

        let row = Controls.row([
            tempoColumn,
            divider(),
            settingsColumn,
            divider(),
            syncLabel
        ], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.Metrics.transportDisplayHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.displayBorder.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: Theme.Metrics.hairline),
            line.heightAnchor.constraint(equalToConstant: 26)
        ])
        return line
    }

    // MARK: - State

    func setTempo(_ beatsPerMinute: Double) {
        tempoField.stringValue = String(format: "%.1f", beatsPerMinute)
    }

    func setClockSource(_ name: String) {
        clockField.value = name
    }

    func setSubdivision(_ name: String) {
        subdivisionField.value = name
    }

    func setSyncStatus(_ text: String) {
        syncLabel.stringValue = text
    }

    func setBeat(_ beatInBar: Int) {
        for (index, light) in beatLights.enumerated() {
            let isCurrent = index == beatInBar
            light.layer?.backgroundColor = isCurrent
                ? Theme.Color.displayText.cgColor
                : Theme.Color.displayDimText.withAlphaComponent(0.3).cgColor
        }
    }
}

/// A caption above a value, where clicking the value advances it.
private final class CyclingField: NSControl, AuditableControl {

    /// Clicking cycles the value, so being wired means having somewhere to report to.
    var isWiredForAudit: Bool { onClick != nil }

    var onClick: (() -> Void)?

    var value: String {
        didSet { valueLabel.stringValue = value }
    }

    private let valueLabel: NSTextField
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(caption: String, value: String) {
        self.value = value
        self.valueLabel = NSTextField(labelWithString: value)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        toolTip = "Click to change \(caption.lowercased())"

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        captionLabel.textColor = Theme.Color.displayDimText

        valueLabel.font = Theme.Font.mono
        valueLabel.textColor = Theme.Color.displayText

        let row = Controls.row([captionLabel, valueLabel], spacing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        // The field has to look clickable, or a value that cycles on click is a
        // secret rather than a control.
        layer?.backgroundColor = Theme.Color.displayHighlight.cgColor
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
