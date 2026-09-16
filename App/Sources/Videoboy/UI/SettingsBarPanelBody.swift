//
//  SettingsBarPanelBody.swift — the Record / Stream / Output / Toggles bar.
//
//  Purpose : SPEC 14.2's bottom bar, spanning the three inner columns. Four labelled
//            sections. Record and Stream are Phase 4+ work and ship disabled; Output
//            and the toggles are live.
//  Inputs  : the negotiated output mode string, for the Output popup's title.
//  Outputs : a single row of sectioned controls.
//  Connects: DisplayRouter (which supplies the negotiated mode text).
//  Extend  : enable a section's controls when its subsystem ships.
//

import AppKit
import VideoboyCore

/// The bottom settings bar.
final class SettingsBarPanelBody: NSView {

    /// The Output section's routing popup, retitled when a mode is negotiated.
    private let outputPopUp: NSPopUpButton

    /// Called when the test-pattern toggle changes.
    var onTestPatternToggled: ((Bool) -> Void)?
    /// Called when the safe-zone toggle changes.
    var onSafeZoneToggled: ((Bool) -> Void)?

    init(negotiatedMode: String) {
        self.outputPopUp = Controls.popUp(["PRI → \(negotiatedMode)"])
        super.init(frame: .zero)

        // Record: needs AVAssetWriter and the discrete-channel plumbing (SPEC 15).
        let record = section("Record", views: [
            Controls.popUp(["ProRes 422"], enabled: false),
            Controls.popUp(["PRI+A/B/C/D"], enabled: false),
            Controls.button("● REC", enabled: false)
        ])

        // Stream: needs the encoder and an egress path (SPEC 15).
        let stream = section("Stream", views: [
            Controls.popUp(["RTMP"], enabled: false),
            Controls.popUp(["2500k"], enabled: false),
            Controls.button("◉ Go Live", enabled: false)
        ])

        // Output: live. The popup title states the mode that was actually negotiated.
        let output = section("Output", views: [
            outputPopUp,
            Controls.popUp(["ONE → (none)"], enabled: false),
            Controls.popUp(["TWO → (none)"], enabled: false)
        ])

        let safeToggle = Controls.toggle(on: false, target: self, action: #selector(safeZoneChanged(_:)))
        let testToggle = Controls.toggle(on: false, target: self, action: #selector(testPatternChanged(_:)))
        let toggles = section("Toggles", views: [
            labelled("Safe", safeToggle),
            // Overscan and black-frame-insertion are Phase 3 CRT features.
            labelled("Overscan", Controls.toggle(enabled: false)),
            labelled("BFI", Controls.toggle(enabled: false)),
            labelled("Test Pat", testToggle)
        ])

        let row = Controls.row([record, stream, output, toggles, Controls.spacer()], spacing: 14)
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

    /// Updates the Output popup after a mode is negotiated.
    func setNegotiatedMode(_ mode: String) {
        outputPopUp.removeAllItems()
        outputPopUp.addItem(withTitle: "PRI → \(mode)")
    }

    /// One labelled section of the bar.
    private func section(_ title: String, views: [NSView]) -> NSStackView {
        let heading = Controls.label(title, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        return Controls.row([heading] + views, spacing: 5)
    }

    /// A toggle with its caption, as the mockup pairs them.
    private func labelled(_ title: String, _ control: NSView) -> NSStackView {
        Controls.row([control, Controls.label(title, font: Theme.Font.tinyLabel)], spacing: 3)
    }

    @objc private func testPatternChanged(_ sender: NSSwitch) {
        Log.info(.output, "test pattern \(sender.state == .on ? "on" : "off")")
        onTestPatternToggled?(sender.state == .on)
    }

    @objc private func safeZoneChanged(_ sender: NSSwitch) {
        Log.info(.output, "safe zones \(sender.state == .on ? "on" : "off")")
        onSafeZoneToggled?(sender.state == .on)
    }
}
