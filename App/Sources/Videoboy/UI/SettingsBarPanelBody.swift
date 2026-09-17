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
    /// The dot between destination and mode, hidden along with the mode.
    private let modeSeparator = Controls.label(
        "·", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary, holdsWidth: true)

    /// Whether output is live. Tally red, because this one means "on air".
    private let outputToggle = VBOptionButton(title: "OUTPUT", onColour: Theme.Color.tallyOnAir)

    private let safeToggle = VBOptionButton(title: "Safe")
    private let overscanToggle = VBOptionButton(title: "Overscan")
    private let bfiToggle = VBOptionButton(title: "BFI")
    private let testToggle = VBOptionButton(title: "Test Pat")
    private let ntscToggle = VBOptionButton(title: "NTSC")
    private let dvToggle = VBOptionButton(title: "DV")

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
    /// NTSC signal emulation on the output was switched.
    var onOutputNTSCToggled: ((Bool) -> Void)?
    /// DV colour-space emulation on the output was switched.
    var onOutputDVToggled: ((Bool) -> Void)?
    /// An emulation toggle was right-clicked, to open its variables. The view is
    /// what the popover hangs from.
    var onEmulationDetailRequested: ((OutputEmulation, NSView) -> Void)?

    init(negotiatedMode: String) {
        super.init(frame: .zero)
        setOutput(destination: "no display", mode: negotiatedMode)

        // OUTPUT — on or off, to where, in what format. The enable is tally red
        // rather than accent blue: this one means "on air", not "option selected".
        outputToggle.target = self
        outputToggle.action = #selector(outputToggleChanged)
        outputToggle.toolTip = "Send PROGRAM to the output display"

        let output = Controls.row([
            outputToggle,
            destinationLabel,
            modeSeparator,
            modeLabel
        ], spacing: Theme.BarSpacing.withinGroup)

        // VIEW — what the CRT sees. No section heading: "Safe", "Overscan", "BFI" and
        // "Test Pat" describe themselves, and a heading over four self-describing
        // buttons is a fifth thing to read for no gain.
        let view = Controls.row([
            option(safeToggle, #selector(safeZoneChanged), "Show the action and title safe areas"),
            option(overscanToggle, #selector(overscanChanged), "Crop to the overscanned area a CRT shows"),
            option(bfiToggle, #selector(blackFrameChanged), "Insert a black frame between fields"),
            option(testToggle, #selector(testPatternChanged), "Send colour bars instead of the mix")
        ], spacing: Theme.BarSpacing.withinGroup)

        // EMULATE — what the signal becomes on its way out. Their three variables
        // each live behind a RIGHT-CLICK rather than a chevron: a truncated mini
        // popup beside a toggle is two controls where one will do, and six of them
        // are what made this bar look busy.
        ntscToggle.onSecondaryClick = { [weak self] anchor in
            self?.onEmulationDetailRequested?(.ntsc, anchor)
        }
        dvToggle.onSecondaryClick = { [weak self] anchor in
            self?.onEmulationDetailRequested?(.dv, anchor)
        }
        let emulate = Controls.row([
            option(ntscToggle, #selector(outputNTSCChanged),
                   "NTSC signal character. Right-click for its settings."),
            option(dvToggle, #selector(outputDVChanged),
                   "DV colour space. Right-click for its settings.")
        ], spacing: Theme.BarSpacing.withinGroup)

        // STREAM — a readout, not a control. The route is chosen from the send glyph
        // under a preview, and a second way to start a stream would be a second thing
        // to keep in step.
        streamLabel.stringValue = "idle"
        streamLabel.font = Theme.Font.tinyLabel
        streamLabel.textColor = Theme.Color.textTertiary

        let row = Controls.row([
            output, divider(), view, divider(), emulate, divider(),
            streamLabel, Controls.spacer()
        ], spacing: Theme.BarSpacing.betweenGroups)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Wires one option button and hands it back, so the rows above stay readable.
    private func option(
        _ button: VBOptionButton, _ action: Selector, _ tooltip: String
    ) -> VBOptionButton {
        button.target = self
        button.action = action
        button.toolTip = tooltip
        return button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private let streamLabel = NSTextField(labelWithString: "idle")
    private var ntscDetailButton: NSButton?

    /// Shows what is being streamed, or "idle".
    func setStreamStatus(_ status: String?) {
        streamLabel.stringValue = status ?? "idle"
        streamLabel.textColor = status == nil
            ? Theme.Color.textTertiary : Theme.Color.accent
    }
    private var dvDetailButton: NSButton?

    @objc private func outputNTSCChanged(_ sender: VBOptionButton) {
        onOutputNTSCToggled?(sender.isOn)
    }

    @objc private func outputDVChanged(_ sender: VBOptionButton) {
        onOutputDVToggled?(sender.isOn)
    }

    /// Updates the destination and mode after the output window has negotiated.
    func setOutput(destination: String, mode: String) {
        destinationLabel.stringValue = destination
        // With no display there is no mode to report, and "not yet negotiated" only
        // truncated to "not yet negotiat…" — which says less than nothing. The
        // separator goes with it, so the group reads as one fact rather than one fact
        // and a stub.
        let hasDisplay = !destination.isEmpty && destination != "no display"
        modeLabel.stringValue = hasDisplay ? mode : ""
        modeLabel.isHidden = !hasDisplay
        modeSeparator.isHidden = !hasDisplay
    }

    /// Reflects output state set from elsewhere, without firing the action.
    func setOutputEnabled(_ enabled: Bool) {
        outputToggle.isOn = enabled
    }

    /// Kept for callers that only have a mode string.
    func setNegotiatedMode(_ mode: String) {
        modeLabel.stringValue = mode
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

    @objc private func outputToggleChanged(_ sender: VBOptionButton) {
        Log.info(.output, "program output \(sender.isOn ? "on" : "off")")
        onOutputEnabledChanged?(sender.isOn)
    }

    @objc private func testPatternChanged(_ sender: VBOptionButton) {
        Log.info(.output, "test pattern \(sender.isOn ? "on" : "off")")
        onTestPatternToggled?(sender.isOn)
    }

    @objc private func safeZoneChanged(_ sender: VBOptionButton) {
        Log.info(.output, "safe zones \(sender.isOn ? "on" : "off")")
        onSafeZoneToggled?(sender.isOn)
    }

    @objc private func overscanChanged(_ sender: VBOptionButton) {
        Log.info(.output, "overscan \(sender.isOn ? "on" : "off")")
        onOverscanToggled?(sender.isOn)
    }

    @objc private func blackFrameChanged(_ sender: VBOptionButton) {
        Log.info(.output, "black-frame insertion \(sender.isOn ? "on" : "off")")
        onBlackFrameInsertionToggled?(sender.isOn)
    }
}
