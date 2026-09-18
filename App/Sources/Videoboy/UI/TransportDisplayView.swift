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
    /// Called when Tap is pressed.
    var onTap: (() -> Void)?


    /// The transport keys, filled in by the toolbar which owns record and play.
    private let transportKeys = NSStackView()

    /// Puts the record and play keys into the cluster, left of Tap.
    ///
    /// They are owned by the toolbar because that is where their callbacks live, but
    /// they belong in the middle of the window with the rest of the transport.
    func setTransportKeys(_ keys: [NSView]) {
        for view in transportKeys.arrangedSubviews {
            transportKeys.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for key in keys { transportKeys.addArrangedSubview(key) }
    }

    /// The recording format, cycled rather than picked from a popup — three choices
    /// do not earn a menu, and a menu does not belong in the top pane at all.
    let formatField = CyclingField(caption: "FMT", value: "ProRes 422")

    /// The tempo readout, which is ALSO how the tempo is set.
    ///
    /// TAP was a separate key beside it — two controls for one value, and a key with
    /// nothing to do at any other moment. Tapping the number is the same gesture
    /// against the thing it changes, and dragging it covers the case tapping cannot:
    /// setting an exact figure you already know.
    private let tempoField = VBTempoField()
    private let clockField = CyclingField(caption: "CLOCK", value: "Internal")
    private let subdivisionField = CyclingField(caption: "DIV", value: "1/4")
    private let syncLabel = NSTextField(labelWithString: "STOPPED")
    private var beatLights: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.Color.displayBackground.cgColor
        layer?.borderWidth = Theme.Metrics.hairline
        layer?.borderColor = Theme.Color.displayBorder.cgColor

        // Tempo, in the camcorder OSD face. This is the number you glance at without
        // looking away from the picture, which is exactly what a viewfinder overlay
        // is for — and it is monospaced, so it does not jitter as it changes.
        tempoField.onTap = { [weak self] in self?.onTap?() }
        tempoField.onTempoDragged = { [weak self] tempo in self?.onTempoEdited?(tempo) }


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

        syncLabel.font = Theme.Font.osd(size: 10)
        syncLabel.textColor = Theme.Color.displayDimText

        clockField.onClick = { [weak self] in self?.onClockSourceCycled?() }
        subdivisionField.onClick = { [weak self] in self?.onSubdivisionCycled?() }

        let tempoColumn = Controls.column([
            tempoField,
            Controls.row(beatLights, spacing: 3)
        ], spacing: 3)

        transportKeys.orientation = .horizontal
        transportKeys.spacing = 4
        transportKeys.alignment = .centerY
        setTransportKeys([])

        let settingsColumn = Controls.column(
            [clockField, subdivisionField, formatField], spacing: 2)


        // Everything that runs a performance lives in this cluster, and it reads
        // outward from the middle: the transport keys, then what they are locked to,
        // then how it is being captured. The record key sits beside play because they
        // are the pair you reach for, and the format beside them because it is the
        // one thing you set before you press record and never during.
        let row = Controls.row([
            transportKeys,
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
        tempoField.beatsPerMinute = beatsPerMinute
    }

    /// Feeds the readout the beat, for its pulse.
    func setBeat(phase: Double, isRunning: Bool) {
        tempoField.beatPhase = phase
        tempoField.isRunning = isRunning
    }

    func setClockSource(_ name: String) {
        clockField.value = name
    }

    func setSubdivision(_ name: String) {
        subdivisionField.value = name
    }

    func setSyncStatus(_ text: String) {
        syncLabel.stringValue = text.uppercased()
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
final class CyclingField: NSControl, AuditableControl {

    /// Clicking cycles the value, so being wired means having somewhere to report to.
    var isWiredForAudit: Bool { onClick != nil }

    var onClick: (() -> Void)?

    var value: String {
        // Upper-cased on the way to the screen, not at the call sites. The camcorder
        // face is an all-caps OSD — a real one has no lower case to draw — so every
        // caller would otherwise have to remember, and one that forgot would be the
        // only mixed-case word on the display.
        didSet { valueLabel.stringValue = value.uppercased() }
    }

    private let valueLabel: NSTextField
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(caption: String, value: String) {
        self.value = value
        self.valueLabel = NSTextField(labelWithString: value.uppercased())
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        toolTip = "Click to change \(caption.lowercased())"

        // CLOCK, DIV and FMT are REFERENCE, not readout. The tempo beside them is the
        // number a hand reaches for and the eye returns to; these three say what mode
        // the machine is in, which you check occasionally and then stop looking at. At
        // 9/12 they competed with the tempo for attention. A step down each keeps them
        // legible and puts the emphasis back where it belongs.
        let captionLabel = NSTextField(labelWithString: caption.uppercased())
        captionLabel.font = Theme.Font.osd(size: 8)
        captionLabel.textColor = Theme.Color.displayDimText

        valueLabel.font = Theme.Font.osd(size: 10)
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
