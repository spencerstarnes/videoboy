//
//  EmulationPopover.swift — the three variables behind each output emulation toggle.
//
//  Purpose : The NTSC and DV toggles on the output bar are meant to be SUBTLE — one
//            switch each, the right defaults, no dialogue. But each has a few things
//            worth reaching when the look is not quite right, and burying them in a
//            preferences pane means nobody finds them mid-set. A popover hung off the
//            toggle, macOS Look Up-style, keeps them one click away and nowhere else.
//  Inputs  : a title, the parameters to show, and the registry they live in.
//  Outputs : values written straight to the registry as the sliders move.
//  Connects: SettingsBarPanelBody (which hangs it), ParamRegistry.
//  Extend  : a fourth variable is a fourth row, but resist it. The argument for these
//            toggles is that they are two switches and not a control panel; a popover
//            that grows into one has lost that.
//

import AppKit
import VideoboyCore

/// Which output emulation a control refers to.
enum OutputEmulation {
    /// The composite signal path: what a picture picks up becoming NTSC.
    case ntsc
    /// The DV round trip: 4:1:1 colour, 8-bit, and generation loss.
    case dv
}

/// A small popover of named sliders bound to param codes on one slot.
final class EmulationPopover: NSViewController {

    /// One row: a caption, a fader, and a live readout.
    struct Variable {
        let caption: String
        let code: ParamCode
        let range: ClosedRange<Double>
        /// Shown disabled with this note when the feature behind it is not built.
        let unavailableNote: String?

        init(
            caption: String, code: ParamCode,
            range: ClosedRange<Double> = 0...1, unavailableNote: String? = nil
        ) {
            self.caption = caption
            self.code = code
            self.range = range
            self.unavailableNote = unavailableNote
        }
    }

    private let heading: String
    private let summary: String
    private let slot: String
    private let variables: [Variable]
    private let registry: ParamRegistry
    private var readouts: [ParamCode: NSTextField] = [:]

    init(
        heading: String, summary: String, slot: String,
        variables: [Variable], registry: ParamRegistry
    ) {
        self.heading = heading
        self.summary = summary
        self.slot = slot
        self.variables = variables
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func loadView() {
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [
            Controls.label(heading, font: Theme.Font.panelTitle, color: Theme.Color.textPrimary),
            Controls.note(summary, width: 260)
        ]

        for variable in variables {
            let caption = Controls.label(
                variable.caption,
                color: variable.unavailableNote == nil
                    ? Theme.Color.textSecondary : Theme.Color.textTertiary,
                holdsWidth: true)

            let value = registry.value(slot: slot, code: variable.code) ?? variable.range.lowerBound
            let normalised = (value - variable.range.lowerBound)
                / max(variable.range.upperBound - variable.range.lowerBound, 0.0001)

            let fader = Controls.fader(
                value: normalised,
                enabled: variable.unavailableNote == nil,
                compact: true,
                mappingSlot: slot, mappingCode: variable.code,
                target: self, action: #selector(faderMoved(_:))
            )
            fader.identifier = NSUserInterfaceItemIdentifier(variable.code.rawValue)

            let readout = Controls.monoLabel(
                Self.format(value, in: variable.range), holdsWidth: true)
            readouts[variable.code] = readout

            rows.append(Controls.row([caption, fader, readout], spacing: 8))
            if let note = variable.unavailableNote {
                rows.append(Controls.note(note, width: 260))
            }
        }

        let column = Controls.column(rows, spacing: 7)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: 300)
        ])
        view = content
    }

    @objc private func faderMoved(_ sender: VBFader) {
        guard let raw = sender.identifier?.rawValue,
              let code = ParamCode(rawValue: raw),
              let variable = variables.first(where: { $0.code == code }) else { return }

        let span = variable.range.upperBound - variable.range.lowerBound
        let value = variable.range.lowerBound + sender.value * span
        registry.setValue(value, slot: slot, code: code)
        readouts[code]?.stringValue = Self.format(value, in: variable.range)
    }

    /// Whole numbers for counts, two decimals for the 0...1 amounts.
    private static func format(_ value: Double, in range: ClosedRange<Double>) -> String {
        range.upperBound > 1.5
            ? String(format: "%.0f", value.rounded())
            : String(format: "%.2f", value)
    }
}
