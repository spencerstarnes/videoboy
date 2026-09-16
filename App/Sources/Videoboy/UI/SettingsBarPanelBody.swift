//
//  SettingsBarPanelBody.swift — the Output / Stream / Toggles bar.
//
//  Purpose : Where the program actually goes, and the CRT-target switches that
//            affect it. This is the "am I on air, and in what format?" strip.
//  Inputs  : the resolved output display and the mode it negotiated.
//  Outputs : an output enable, and the toggle callbacks.
//  Connects: DisplayRouter (which supplies the display and mode), ShellController.
//
//  It was previously four unlabelled rows of popups reading things like
//  "PRI → not yet negotiated", which said nothing useful: it did not say which
//  display, whether anything was being sent, or what "negotiated" meant. Now the
//  Output section states the destination, states the mode, and carries the switch
//  that starts and stops it — the three things actually being asked.
//

import AppKit
import VideoboyCore

/// The bottom bar: output, streaming, and the CRT toggles.
final class SettingsBarPanelBody: NSView {

    /// Destination name, e.g. the display the program window is on.
    private let destinationLabel = Controls.monoLabel("no display")
    /// The mode actually negotiated with that display.
    private let modeLabel = Controls.monoLabel("—")

    /// Whether output is live.
    private let outputSwitch: NSSwitch

    /// Called when output is switched on or off.
    var onOutputEnabledChanged: ((Bool) -> Void)?
    /// Called when the test-pattern toggle changes.
    var onTestPatternToggled: ((Bool) -> Void)?
    /// Called when the safe-zone toggle changes.
    var onSafeZoneToggled: ((Bool) -> Void)?
    /// Called when the overscan toggle changes.
    var onOverscanToggled: ((Bool) -> Void)?
    /// Called when black-frame insertion is toggled.
    var onBlackFrameInsertionToggled: ((Bool) -> Void)?

    init(negotiatedMode: String) {
        outputSwitch = NSSwitch()
        super.init(frame: .zero)

        modeLabel.stringValue = negotiatedMode

        outputSwitch.state = .off
        outputSwitch.controlSize = .mini
        outputSwitch.target = self
        outputSwitch.action = #selector(outputEnabledChanged(_:))

        // OUTPUT — the only section here that does anything yet, so it leads and
        // gets the room. It answers: on or off, to where, and in what format.
        let output = section("Output", views: [
            outputSwitch,
            Controls.label("PROGRAM →", font: Theme.Font.tinyLabel,
                           color: Theme.Color.textTertiary, holdsWidth: true),
            destinationLabel,
            Controls.label("·", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary),
            modeLabel
        ])

        // TOGGLES — what the CRT sees.
        let safeToggle = Controls.toggle(on: false, target: self, action: #selector(safeZoneChanged(_:)))
        let testToggle = Controls.toggle(on: false, target: self, action: #selector(testPatternChanged(_:)))
        let overscanToggle = Controls.toggle(on: false, target: self, action: #selector(overscanChanged(_:)))
        let bfiToggle = Controls.toggle(on: false, target: self, action: #selector(blackFrameChanged(_:)))
        let toggles = section("View", views: [
            labelled("Safe", safeToggle),
            labelled("Overscan", overscanToggle),
            labelled("BFI", bfiToggle),
            labelled("Test Pat", testToggle)
        ])

        // STREAM — not built. Marked as such rather than left as live-looking popups.
        let stream = section("Stream", views: [
            Controls.label("not built", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        ])

        let row = Controls.row([
            output, divider(), toggles, divider(), stream, Controls.spacer()
        ], spacing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Updates the destination and mode after the output window has negotiated.
    func setOutput(destination: String, mode: String) {
        destinationLabel.stringValue = destination
        modeLabel.stringValue = mode
    }

    /// Reflects output state set from elsewhere, without firing the action.
    func setOutputEnabled(_ enabled: Bool) {
        outputSwitch.state = enabled ? .on : .off
    }

    /// Kept for callers that only have a mode string.
    func setNegotiatedMode(_ mode: String) {
        modeLabel.stringValue = mode
    }

    /// One labelled section of the bar.
    private func section(_ title: String, views: [NSView]) -> NSStackView {
        let heading = Controls.label(
            title, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary, holdsWidth: true)
        return Controls.row([heading] + views, spacing: 5)
    }

    /// A toggle with its caption, as the mockup pairs them.
    private func labelled(_ title: String, _ control: NSView) -> NSStackView {
        Controls.row([
            control,
            Controls.label(title, font: Theme.Font.tinyLabel, holdsWidth: true)
        ], spacing: 3)
    }

    /// A vertical rule between sections — a rule rather than more space, so the bar
    /// reads as distinct groups without spreading them across the window.
    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.separator.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: Theme.Metrics.hairline),
            line.heightAnchor.constraint(equalToConstant: 16)
        ])
        return line
    }

    @objc private func outputEnabledChanged(_ sender: NSSwitch) {
        Log.info(.output, "program output \(sender.state == .on ? "on" : "off")")
        onOutputEnabledChanged?(sender.state == .on)
    }

    @objc private func testPatternChanged(_ sender: NSSwitch) {
        Log.info(.output, "test pattern \(sender.state == .on ? "on" : "off")")
        onTestPatternToggled?(sender.state == .on)
    }

    @objc private func safeZoneChanged(_ sender: NSSwitch) {
        Log.info(.output, "safe zones \(sender.state == .on ? "on" : "off")")
        onSafeZoneToggled?(sender.state == .on)
    }

    @objc private func overscanChanged(_ sender: NSSwitch) {
        Log.info(.output, "overscan \(sender.state == .on ? "on" : "off")")
        onOverscanToggled?(sender.state == .on)
    }

    @objc private func blackFrameChanged(_ sender: NSSwitch) {
        Log.info(.output, "black-frame insertion \(sender.state == .on ? "on" : "off")")
        onBlackFrameInsertionToggled?(sender.state == .on)
    }
}
