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
    /// Which modulation sources are driving anything on this effect, by badge.
    var activeModulation: Set<String> = []
    /// Channel letters this card can target, e.g. ["A", "B"]. Empty means the card
    /// has exactly one target and no selector is drawn.
    ///
    /// This exists because SPEC 2's chFX runs once per CHANNEL, not once per bus —
    /// A and B each carry their own bitstream wedge — but the panel only has room to
    /// show one card's worth of controls at a time. The selector is what lets one
    /// card reach either channel rather than the card being hardwired to whichever
    /// channel got there first.
    var channelOptions: [String] = []
}

/// Where a parameter's movement can come from, other than a hand on the fader.
///
/// Spelled out rather than initialled. "M S C" was three single letters in a column,
/// and the first two are exactly what a mixer uses for Mute and Solo — so the badges
/// read as channel controls on a device that has neither. These are three-letter
/// words instead: short enough for a narrow card, long enough to mean something.
enum ModulationSource: String, CaseIterable {
    case midi
    case audio
    case lfo

    /// What appears on the badge.
    var badge: String {
        switch self {
        case .midi: "MIDI"
        case .audio: "AUD"
        case .lfo: "LFO"
        }
    }

    /// The letter the engine and the menus have always used for this source.
    ///
    /// The internal identifier does not change with the label: mappings, templates
    /// and `setBadgeActive` all key off these, and renaming what is on screen must
    /// not rename what is saved to disk.
    var legacyLetter: String {
        switch self {
        case .midi: "M"
        case .audio: "S"
        case .lfo: "C"
        }
    }

    var explanation: String {
        switch self {
        case .midi: "Drive this effect from a MIDI controller"
        case .audio: "Drive this effect from the audio input"
        case .lfo: "Drive this effect from an LFO locked to the transport"
        }
    }

    static func fromBadge(_ badge: String) -> ModulationSource? {
        allCases.first { $0.badge == badge }
    }
}

/// A scrolling, reorderable chain of effect cards.
final class EffectChainPanelBody: NSView {

    private let stack = NSStackView()
    private var cardViews: [NSView] = []
    private(set) var effects: [EffectCardModel]

    /// Which graph slot a param code belongs to, so a Shift-click on a parameter's
    /// fader can arm a mapping without the panel knowing anything about MIDI.
    /// Set by the shell, which owns the slot tables.
    var mappingSlotForCode: ((ParamCode) -> String?)? {
        // The rows are built in init, before the shell has anything to resolve with,
        // so setting the resolver has to reach back and address the faders that
        // already exist. Without this every FX fader stays dark under Shift, which
        // looks exactly like a deliberate decision not to make them mappable.
        didSet { refreshMappingAddresses() }
    }

    /// Gives every parameter fader beneath this panel its slot, from the resolver.
    func refreshMappingAddresses() {
        refreshMappingAddresses(in: self)
    }

    private func refreshMappingAddresses(in view: NSView) {
        if let fader = view as? VBFader,
           let raw = fader.identifier?.rawValue,
           let code = ParamCode(rawValue: raw) {
            fader.mappingCode = code
            fader.mappingSlot = mappingSlotForCode?(code)
        }
        for subview in view.subviews { refreshMappingAddresses(in: subview) }
    }

    /// Called after the card views are rebuilt, so their state can be restored.
    var onChainRebuilt: (() -> Void)?

    /// Called when a parameter fader moves: (param code, new 0...1 value).
    var onParameterChanged: ((String, Double) -> Void)?

    /// A modulation badge on an effect header was clicked: (effect name, source,
    /// the badge view to hang a menu from).
    var onEffectModulationRequested: ((String, ModulationSource, NSView) -> Void)?

    /// A card's channel selector changed: (effect name, index into its
    /// `channelOptions`).
    var onCardChannelChanged: ((String, Int) -> Void)?

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

    /// Which channel each channel-selecting card is currently pointed at, by effect
    /// name. Kept here rather than in `EffectCardModel` so a rebuild (reordering,
    /// enabling) does not reset a choice the performer just made.
    private var cardChannelSelection: [String: Int] = [:]

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

        onChainRebuilt?()
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

        let removeButton = Controls.glyphButton(
            "✕", enabled: effect.isImplemented,
            tooltip: "Take \(effect.name) out of this chain",
            target: self, action: #selector(effectRemoved(_:)))
        removeButton.identifier = NSUserInterfaceItemIdentifier(effect.name)

        // The channel selector, for chFX cards — an effect that runs once per
        // CHANNEL (SPEC 2) rather than once per bus, where the panel only has room
        // for one card's worth of controls. Small and in the same family as the
        // A/B · C/D toggle on the libraries, so it reads as the same kind of choice.
        var channelSelector: NSSegmentedControl?
        if effect.channelOptions.count > 1 {
            let selected = cardChannelSelection[effect.name] ?? 0
            // The focused channel carries the same caret the library's load focus
            // uses, so the two read as one kind of switch: the one that receives
            // what you do next.
            let focusTitles = effect.channelOptions.enumerated().map { index, name in
                index == selected ? Theme.focusCaret + name : name
            }
            let selector = Controls.segmented(
                focusTitles,
                selected: min(selected, effect.channelOptions.count - 1),
                enabled: effect.isImplemented,
                target: self, action: #selector(cardChannelChanged(_:))
            )
            selector.identifier = NSUserInterfaceItemIdentifier(effect.name)
            selector.toolTip = "Focus — which channel this effect's controls edit"
            channelSelector = selector
        }

        // The three modulation sources, once per EFFECT rather than once per
        // parameter. Spelled out, because "M S C" reads as Mute/Solo/... to anyone
        // who has used an audio mixer — and this app has no mute and no solo. They
        // were also a column of decoration on every parameter row, repeated five or
        // six times down a card that is already narrow.
        //
        // Individual parameters are still individually mappable: hold Shift and click
        // any fader. That gesture arrived after these badges did and quietly made the
        // per-parameter column redundant.
        var headerViews: [NSView] = [grip, nameLabel]
        if let channelSelector { headerViews.append(channelSelector) }
        headerViews.append(Controls.spacer())
        if !effect.isImplemented {
            let note = Controls.label("not built", font: Theme.Font.tinyLabel,
                                      color: Theme.Color.textTertiary)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(note)
        }
        headerViews.append(enableSwitch)
        headerViews.append(removeButton)
        let header = Controls.row(headerViews, spacing: 4)

        // The badges get their own line. Spelled-out names do not fit beside a grip,
        // a name, a switch and a close button in a column this narrow — the first
        // attempt truncated LFO to "L…", which is exactly the failure that made the
        // single letters ambiguous in the first place. A line of their own costs one
        // row and keeps the words whole.
        var modulationRow: NSView?
        if effect.isImplemented {
            var badges: [NSView] = []
            for source in ModulationSource.allCases {
                let button = Controls.mappingBadgeButton(
                    source.badge,
                    isActive: effect.activeModulation.contains(source.badge),
                    target: self, action: #selector(effectBadgeClicked(_:))
                )
                button.identifier = NSUserInterfaceItemIdentifier("\(effect.name)|\(source.badge)")
                button.toolTip = source.explanation
                badges.append(button)
            }
            badges.append(Controls.spacer())
            modulationRow = Controls.row(badges, spacing: 3)
        }

        // ---- Parameters: two lines each ----
        var rows: [NSView] = [header]
        if let modulationRow { rows.append(modulationRow) }
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
        // Line 1 — name with its param code, and the current value. No badge column:
        // it said the same three things on every row of every card, and Shift-click
        // maps a parameter without needing a control of its own.
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

        let topLine = Controls.row([label, Controls.spacer(), value], spacing: 5)

        // Line 2 — the fader, full width. This is the whole reason for two lines.
        let fader = Controls.fader(
            value: parameter.value, enabled: parameter.enabled,
            target: self, action: #selector(faderMoved(_:))
        )
        fader.identifier = NSUserInterfaceItemIdentifier(parameter.code)
        if let code = ParamCode(rawValue: parameter.code) {
            fader.mappingCode = code
            fader.mappingSlot = mappingSlotForCode?(code)
        }

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

    /// A badge on an effect's header. Reports the effect name and the source's
    /// internal letter, which is what the engine and the saved templates key off.
    @objc private func effectBadgeClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let source = ModulationSource.fromBadge(parts[1]) else { return }
        onEffectModulationRequested?(parts[0], source, sender)
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectToggled?(name, sender.state == .on)
    }

    /// Moves the focus caret to the selected segment.
    private func restyleFocus(_ control: NSSegmentedControl, options: [String]) {
        for (index, name) in options.enumerated() {
            control.setLabel(
                index == control.selectedSegment ? Theme.focusCaret + name : name,
                forSegment: index)
        }
    }

    @objc private func cardChannelChanged(_ sender: NSSegmentedControl) {
        guard let name = sender.identifier?.rawValue else { return }
        let index = sender.selectedSegment
        cardChannelSelection[name] = index
        if let options = effects.first(where: { $0.name == name })?.channelOptions {
            restyleFocus(sender, options: options)
        }
        onCardChannelChanged?(name, index)
    }

    /// Pushes new values into a specific card's parameter faders and readouts, for
    /// when what the card should show changed for a reason other than a drag on the
    /// fader itself — here, its channel selector pointing somewhere else.
    ///
    /// Targeted rather than a full `rebuild()`: rebuilding would also reset scroll
    /// position and drop the in-flight drag-reorder state, for a change that is only
    /// ever "this fader's number is now different."
    func setDisplayedParameterValues(effectName: String, values: [String: Double]) {
        guard let index = effects.firstIndex(where: { $0.name == effectName }),
              cardViews.indices.contains(index + 1) else { return }
        let card = cardViews[index + 1]

        for (code, value) in values {
            for case let fader as VBFader in allSubviews(of: card)
            where fader.identifier?.rawValue == code {
                fader.value = value
            }
            for case let label as NSTextField in allSubviews(of: card)
            where label.identifier?.rawValue == "value|\(code)" {
                label.stringValue = String(format: "%.2f", value)
            }
        }
    }

    /// Sets a card's enable switch directly, for when what it should show changed
    /// for a reason other than someone flipping it — here, its channel selector
    /// pointing at a channel with its own, independent bypass state.
    func setEnabled(effectName: String, isOn: Bool) {
        guard let index = effects.firstIndex(where: { $0.name == effectName }),
              cardViews.indices.contains(index + 1) else { return }
        let card = cardViews[index + 1]
        for case let toggle as NSSwitch in allSubviews(of: card)
        where toggle.identifier?.rawValue == effectName {
            toggle.state = isOn ? .on : .off
        }
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

    /// Repaints an effect's badge to show whether that source is driving it.
    func setEffectModulationActive(
        effect: String, source: ModulationSource, isActive: Bool
    ) {
        let identifier = NSUserInterfaceItemIdentifier("\(effect)|\(source.badge)")
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
