//
//  EffectChainPanelBody.swift — the tall per-sub-mix effect chain (SPEC 14.2).
//
//  Purpose : The ordered effect chain for one sub-mix: a Load/Save row, then a card
//            per effect with an enable switch, a remove button, and parameter rows
//            carrying their param codes and mapping badges.
//  Inputs  : the effects to show, as `EffectCardModel`s.
//  Outputs : a scrolling stack of effect cards.
//  Connects: Controls, Theme; later, Core's render graph supplies the real chain.
//  Extend  : the wedge's corruptor parameters appear here as ordinary parameter rows
//            — that is the point of the param-code table (SPEC 13).
//

import AppKit
import VideoboyCore

/// One parameter row inside an effect card.
struct EffectParameterModel {
    /// Display name, e.g. "rate".
    let name: String
    /// Stable param code from SPEC 13, e.g. "33B". Shown so mappings are legible.
    let code: String
    /// Current value, 0...1.
    let value: Double
    /// Mapping badges currently lit: "M" MIDI, "S" audio-react, "C" clock-LFO.
    let activeBadges: Set<String>
    /// False for parameters whose feature is not built yet.
    let enabled: Bool
}

/// One effect card in a chain.
struct EffectCardModel {
    let name: String
    let isEnabled: Bool
    /// False when the effect's implementation is not built yet.
    let isImplemented: Bool
    let parameters: [EffectParameterModel]
}

/// A scrolling ordered chain of effect cards.
final class EffectChainPanelBody: NSView {

    private let stack = NSStackView()

    /// Called when a parameter slider moves: (param code, new 0...1 value).
    var onParameterChanged: ((String, Double) -> Void)?

    /// Called when a mapping badge is clicked: (param code, which badge).
    /// "M" arms MIDI detect, "S" offers audio taps, "C" offers an LFO.
    var onMappingBadgeClicked: ((String, String, NSView) -> Void)?

    /// Called when an effect's enable switch is toggled: (effect name, on).
    var onEffectToggled: ((String, Bool) -> Void)?

    init(effects: [EffectCardModel]) {
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Metrics.controlSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Theme.Metrics.panelBodyPadding, left: Theme.Metrics.panelBodyPadding,
            bottom: Theme.Metrics.panelBodyPadding, right: Theme.Metrics.panelBodyPadding
        )

        // Load Asset / Save row, as in the mockup.
        let loadRow = Controls.row([
            Controls.popUp(["Load Asset…"], enabled: false),
            Controls.button("Save", enabled: false)
        ], spacing: 3)
        stack.addArrangedSubview(loadRow)

        for effect in effects {
            stack.addArrangedSubview(makeCard(effect))
        }

        // A flipped document view keeps the chain growing downward from the top.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Pinning the document's width to the clip view's makes the scroll
            // view vertical-only; its height then follows the stack's content.
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Builds one effect card: header row plus its parameter rows.
    private func makeCard(_ effect: EffectCardModel) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        card.layer?.borderColor = Theme.Color.panelBorder.cgColor
        card.layer?.borderWidth = Theme.Metrics.hairline
        card.layer?.cornerRadius = Theme.Metrics.buttonCornerRadius

        let enableSwitch = Controls.toggle(
            on: effect.isEnabled, enabled: effect.isImplemented,
            target: self, action: #selector(effectToggled(_:))
        )
        // The switch carries its effect's name so one action can serve every card.
        enableSwitch.identifier = NSUserInterfaceItemIdentifier(effect.name)

        let nameLabel = Controls.label(
            effect.name, font: Theme.Font.label,
            color: effect.isImplemented ? Theme.Color.textPrimary : Theme.Color.textTertiary
        )

        // The effect's name must survive a narrow column; the "not yet implemented"
        // note is the first thing that should be truncated, not the last.
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        var headerViews: [NSView] = [
            Controls.label("▾", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary),
            nameLabel,
            Controls.spacer()
        ]
        if !effect.isImplemented {
            let note = Controls.label("not yet implemented", font: Theme.Font.tinyLabel,
                                      color: Theme.Color.textTertiary)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(note)
        }
        headerViews.append(enableSwitch)
        headerViews.append(Controls.button("✕", enabled: false))

        let header = Controls.row(headerViews, spacing: 5)
        let rows = effect.parameters.map(makeParameterRow)
        let column = Controls.column([header] + rows, spacing: 3)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            header.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return card
    }

    /// One parameter row: mapping badges, label with param code, slider, value.
    private func makeParameterRow(_ parameter: EffectParameterModel) -> NSStackView {
        // The badges are clickable for a live parameter: that is how a performer
        // reaches MIDI learn, an audio tap or an LFO without leaving the panel.
        let badges: NSStackView
        if parameter.enabled {
            let buttons = ["M", "S", "C"].map { letter -> NSButton in
                let button = Controls.mappingBadgeButton(
                    letter,
                    isActive: parameter.activeBadges.contains(letter),
                    target: self, action: #selector(badgeClicked(_:))
                )
                // The code and the letter together identify what was clicked.
                button.identifier = NSUserInterfaceItemIdentifier("\(parameter.code)|\(letter)")
                return button
            }
            badges = Controls.row(buttons, spacing: 0)
        } else {
            badges = Controls.mappingBadges(["M", "S", "C"], active: parameter.activeBadges)
        }
        // The param code is shown next to the name because mappings target the code,
        // not the module instance (SPEC 13) — so the code is the thing worth reading.
        let label = Controls.monoLabel(
            "\(parameter.name)·\(parameter.code)",
            color: parameter.enabled ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        let slider = Controls.slider(
            value: parameter.value, enabled: parameter.enabled,
            target: self, action: #selector(parameterMoved(_:))
        )
        slider.identifier = NSUserInterfaceItemIdentifier(parameter.code)
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        let value = Controls.monoLabel(String(format: "%.2f", parameter.value))

        let row = Controls.row([badges, label, slider, value], spacing: 6)
        return row
    }

    @objc private func parameterMoved(_ sender: NSSlider) {
        guard let code = sender.identifier?.rawValue else { return }
        // Update the numeric readout that sits to the slider's right.
        if let row = sender.superview as? NSStackView,
           let readout = row.arrangedSubviews.last as? NSTextField {
            readout.stringValue = String(format: "%.2f", sender.doubleValue)
        }
        onParameterChanged?(code, sender.doubleValue)
    }

    @objc private func badgeClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        onMappingBadgeClicked?(parts[0], parts[1], sender)
    }

    /// Repaints a badge to show whether its parameter is currently driven.
    func setBadgeActive(code: String, badge: String, isActive: Bool) {
        let identifier = NSUserInterfaceItemIdentifier("\(code)|\(badge)")
        for case let button as NSButton in allSubviews(of: stack)
        where button.identifier == identifier {
            button.contentTintColor = isActive ? Theme.Color.accent : Theme.Color.textTertiary
        }
    }

    /// Every view beneath a root, flattened. Small trees only — this walks the
    /// effect chain's own rows, not the whole window.
    private func allSubviews(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectToggled?(name, sender.state == .on)
    }
}
