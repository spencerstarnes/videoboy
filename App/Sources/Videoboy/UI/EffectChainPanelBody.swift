//
//  EffectChainPanelBody.swift — the tall per-sub-mix effect chain (SPEC 14.2).
//
//  Purpose : The ordered effect chain for one sub-mix. Each effect is a card that can
//            be enabled, removed, reordered, and whose parameters can be set and
//            modulated.
//  Inputs  : the effects to show, as `EffectCardModel`s.
//  Outputs : a scrolling stack of effect cards, plus callbacks for every interaction.
//  Connects: VBFader (the controls), DragHandleView (reordering), ModulationMenus
//            (the M/S/C badges), ShellController (which applies the results).
//
//  LAYOUT — each parameter takes two lines, not one:
//
//      M S C   amount·31B                                    0.42
//      ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬●▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
//
//  The badges, name and value share the top line; the fader gets the full width of
//  the panel to itself. Cramming all of it onto one line is what made the faders
//  unreadable — in a column this narrow the control was left with perhaps forty
//  points of travel.
//
//  ORDER — the list reads like Photoshop layers: the card at the TOP is the last
//  thing applied, so it is what you see on top. Signal therefore flows from the
//  bottom card upward. `renderOrder` is the one place that inversion happens.
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

/// A scrolling, reorderable chain of effect cards.
final class EffectChainPanelBody: NSView {

    private let stack = NSStackView()
    private var cardViews: [NSView] = []
    private(set) var effects: [EffectCardModel]

    /// Called when a parameter fader moves: (param code, new 0...1 value).
    var onParameterChanged: ((String, Double) -> Void)?

    /// Called when a mapping badge is clicked: (param code, which badge, the badge view).
    var onMappingBadgeClicked: ((String, String, NSView) -> Void)?

    /// Called when an effect's enable switch is toggled: (effect name, on).
    var onEffectToggled: ((String, Bool) -> Void)?

    /// Called when the chain is reordered, with the new top-to-bottom name order.
    var onReordered: (([String]) -> Void)?

    /// Called when an effect's ✕ is pressed.
    var onEffectRemoved: ((String) -> Void)?

    /// Called when an effect is added back from the Add popup.
    var onEffectAdded: ((String) -> Void)?

    /// Effects taken out of the chain, kept so they can be put back.
    private var removedEffects: [EffectCardModel] = []

    init(effects: [EffectCardModel]) {
        self.effects = effects
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

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

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// The chain in the order it should be APPLIED.
    ///
    /// The list is shown top-down like Photoshop layers, where the top card is what
    /// ends up on top — so it is applied last, and the signal runs up the list. This
    /// is the only place that inversion lives; everything else deals in display order.
    var renderOrder: [String] {
        effects.map(\.name).reversed()
    }

    // MARK: - Building

    private func rebuild() {
        for view in cardViews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        cardViews.removeAll()

        // Add / Save row at the top, above the layer stack. The Add popup lists what
        // has been removed, so ✕ is reversible rather than a one-way door.
        let addPopUp = Controls.popUp(
            ["Add effect…"] + removedEffects.map(\.name),
            enabled: !removedEffects.isEmpty,
            target: self, action: #selector(addEffectChosen(_:))
        )
        let loadRow = Controls.row([
            addPopUp,
            Controls.button("Save", enabled: false)
        ], spacing: 3)
        stack.addArrangedSubview(loadRow)
        cardViews.append(loadRow)
        loadRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true

        for (index, effect) in effects.enumerated() {
            let card = makeCard(effect, index: index)
            stack.addArrangedSubview(card)
            cardViews.append(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    /// Builds one effect card.
    private func makeCard(_ effect: EffectCardModel, index: Int) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        card.layer?.borderColor = Theme.Color.panelBorder.cgColor
        card.layer?.borderWidth = Theme.Metrics.hairline
        card.layer?.cornerRadius = Theme.Metrics.buttonCornerRadius

        // ---- Header: grip, name, enable, remove ----
        let grip = DragHandleView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onDrag = { [weak self] offset in
            self?.previewReorder(of: index, by: offset)
        }
        grip.onDragEnded = { [weak self] in
            self?.commitReorder()
        }

        let nameLabel = Controls.label(
            effect.name, font: Theme.Font.label,
            color: effect.isImplemented ? Theme.Color.textPrimary : Theme.Color.textTertiary
        )
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // The outer FX columns are narrow, so a long effect name will truncate. The
        // full name stays reachable rather than lost.
        nameLabel.toolTip = effect.name

        let enableSwitch = Controls.toggle(
            on: effect.isEnabled, enabled: effect.isImplemented,
            target: self, action: #selector(effectToggled(_:))
        )
        enableSwitch.identifier = NSUserInterfaceItemIdentifier(effect.name)

        let removeButton = Controls.button("✕", enabled: effect.isImplemented,
                                           target: self, action: #selector(effectRemoved(_:)))
        removeButton.identifier = NSUserInterfaceItemIdentifier(effect.name)

        var headerViews: [NSView] = [grip, nameLabel, Controls.spacer()]
        if !effect.isImplemented {
            let note = Controls.label("not built", font: Theme.Font.tinyLabel,
                                      color: Theme.Color.textTertiary)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(note)
        }
        headerViews.append(enableSwitch)
        headerViews.append(removeButton)
        let header = Controls.row(headerViews, spacing: 5)

        // ---- Parameters: two lines each ----
        var rows: [NSView] = [header]
        for parameter in effect.parameters {
            rows.append(contentsOf: makeParameterRows(parameter))
        }

        let column = Controls.column(rows, spacing: 3)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5)
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return card
    }

    /// The two lines for one parameter: badges/name/value, then a full-width fader.
    private func makeParameterRows(_ parameter: EffectParameterModel) -> [NSView] {
        // Line 1 — badges, name with its param code, and the current value.
        let badges: NSStackView
        if parameter.enabled {
            let buttons = ["M", "S", "C"].map { letter -> NSButton in
                let button = Controls.mappingBadgeButton(
                    letter,
                    isActive: parameter.activeBadges.contains(letter),
                    target: self, action: #selector(badgeClicked(_:))
                )
                button.identifier = NSUserInterfaceItemIdentifier("\(parameter.code)|\(letter)")
                return button
            }
            badges = Controls.row(buttons, spacing: 0)
        } else {
            badges = Controls.mappingBadges(["M", "S", "C"], active: parameter.activeBadges)
        }

        let label = Controls.monoLabel(
            "\(parameter.name)·\(parameter.code)",
            color: parameter.enabled ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        // Fixed width, so the row does not twitch as the digits change under a drag,
        // and so the readout is never what gets truncated when the column is narrow.
        let value = Controls.monoLabel(String(format: "%.2f", parameter.value))
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(
            equalToConstant: Theme.Metrics.valueReadoutWidth).isActive = true
        value.identifier = NSUserInterfaceItemIdentifier("value|\(parameter.code)")

        let topLine = Controls.row([badges, label, Controls.spacer(), value], spacing: 5)

        // Line 2 — the fader, full width. This is the whole reason for two lines.
        let fader = Controls.fader(
            value: parameter.value, enabled: parameter.enabled,
            target: self, action: #selector(faderMoved(_:))
        )
        fader.identifier = NSUserInterfaceItemIdentifier(parameter.code)

        return [topLine, fader]
    }

    // MARK: - Reordering

    /// Offset applied to the dragged card while the drag is in progress.
    private var draggingIndex: Int?
    private var pendingOrder: [EffectCardModel]?

    /// Moves the dragged card past its neighbours as the pointer travels.
    ///
    /// Cards are a similar height, so a drag of roughly one card height means one
    /// position. Measuring the actual neighbour heights would be more precise, but a
    /// chain of near-identical rows does not need it.
    private func previewReorder(of index: Int, by offset: CGFloat) {
        let approximateCardHeight: CGFloat = 46
        let steps = Int((offset / approximateCardHeight).rounded())
        guard steps != 0 else { return }

        var reordered = pendingOrder ?? effects
        let from = draggingIndex ?? index
        let to = min(max(from + steps, 0), reordered.count - 1)
        guard to != from else { return }

        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: to)
        pendingOrder = reordered
        draggingIndex = to
        effects = reordered
        rebuild()
    }

    /// Finalises a reorder and tells the app the new order.
    private func commitReorder() {
        defer {
            draggingIndex = nil
            pendingOrder = nil
        }
        guard pendingOrder != nil else { return }
        Log.info(.graph, "effect chain reordered: \(effects.map(\.name).joined(separator: " → "))")
        onReordered?(effects.map(\.name))
    }

    // MARK: - Actions

    @objc private func faderMoved(_ sender: VBFader) {
        guard let code = sender.identifier?.rawValue else { return }
        // Update the readout on the line above.
        let identifier = NSUserInterfaceItemIdentifier("value|\(code)")
        for case let field as NSTextField in allSubviews(of: stack)
        where field.identifier == identifier {
            field.stringValue = String(format: "%.2f", sender.value)
        }
        onParameterChanged?(code, sender.value)
    }

    @objc private func badgeClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        onMappingBadgeClicked?(parts[0], parts[1], sender)
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectToggled?(name, sender.state == .on)
    }

    @objc private func effectRemoved(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectRemoved?(name)
    }

    @objc private func addEffectChosen(_ sender: NSPopUpButton) {
        // Item 0 is the prompt, not a choice.
        guard sender.indexOfSelectedItem > 0 else { return }
        let name = sender.titleOfSelectedItem ?? ""
        onEffectAdded?(name)
    }

    /// Takes an effect's card out of the chain, remembering it for the Add popup.
    func removeEffect(named name: String) {
        guard let index = effects.firstIndex(where: { $0.name == name }) else { return }
        removedEffects.append(effects.remove(at: index))
        rebuild()
    }

    /// Puts a removed effect back at the end of the chain, bypassed.
    func restoreEffect(named name: String) {
        guard let index = removedEffects.firstIndex(where: { $0.name == name }) else { return }
        var restored = removedEffects.remove(at: index)
        restored = EffectCardModel(
            name: restored.name, isEnabled: false,
            isImplemented: restored.isImplemented, parameters: restored.parameters)
        effects.append(restored)
        rebuild()
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
}
