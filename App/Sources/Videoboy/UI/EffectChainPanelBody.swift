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
    /// What the readout says for a fader position (0...1): "on", a choice's label, a
    /// number in the parameter's own units. Nil shows the position itself.
    var valueText: ((Double) -> String)? = nil
    /// A trigger (`ModuleControlKind.trigger`): drawn as a momentary key, not a fader.
    /// 1 while held, 0 on release — the same two values a MIDI note sends.
    var isTrigger = false
    /// For a trigger that can be armed on the beat (`ModuleBeatArm`): which choice
    /// on the same card fires it, in 0...1 fader positions.
    var beatArm: BeatArmModel? = nil
    /// What the control does (`ModuleControl.help`): the row's tooltip.
    var help: String? = nil

    /// The readout for a fader position.
    func text(for value: Double) -> String {
        valueText?(value) ?? String(format: "%.2f", value)
    }
}

/// How Option-Command-click arms a trigger key on the beat, in fader positions.
struct BeatArmModel {
    /// The code of the choice on the same card that fires the trigger ("heal every").
    let code: String
    /// Where arming puts that choice's fader the first time.
    let armedValue: Double
    /// Whether a fader position means "firing on the beat".
    let isArmed: (Double) -> Bool
}

/// One effect card in a chain.
struct EffectCardModel {
    /// The card's title, unique within its panel ("Bad TV", "Bad TV 2"). Controls on
    /// the card are identified by it.
    let name: String
    /// The chain instance behind the card (`EffectChain`), or the name when the card
    /// is not a chain instance.
    var id: String = ""
    /// Where the module came from, shown small on the card: "built-in", "ISF".
    var badge: String? = nil
    /// A line under the header when the module is not simply running: "compiling…",
    /// "⚠ line 14: …", "⚠ module missing".
    var status: String? = nil
    let isEnabled: Bool
    /// False when the effect's implementation is not built yet.
    let isImplemented: Bool
    let parameters: [EffectParameterModel]
    /// Which modulation sources are driving anything on this effect, by badge.
    var activeModulation: Set<String> = []
    /// A neutral line under the header — what the Source Controls card is showing
    /// ("A · 01_Strobosphere"). `status` is for problems and is drawn in their colour.
    var subtitle: String? = nil
    /// The whole story behind `subtitle`, as its tooltip. The line itself is kept
    /// short enough to fit the narrow FX column; this is where the detail goes.
    var subtitleDetail: String? = nil
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

    /// The title of the pinned card, which is also how its controls are addressed.
    static let sourceCardName = "Source Controls"

    /// SOURCE CONTROLS: the parameters of whatever a channel is playing — an ISF
    /// generator's own inputs, a built-in pattern's scale and phase. Pinned ABOVE the
    /// scrolling chain, outside it: it cannot be dragged, removed or bypassed, and it
    /// never scrolls away, because it is not an effect in the chain but the thing the
    /// chain is applied to. Nil draws nothing.
    var sourceCard: EffectCardModel? {
        didSet { rebuildSourceCard() }
    }

    /// Holds the pinned card, glued to the top of the panel.
    private let sourceContainer = NSView()
    private weak var sourceCardView: NSView?

    /// Effects folded down to their header, by name.
    ///
    /// By NAME rather than by index, because the chain reorders and a collapsed card
    /// has to stay collapsed when it moves — an index would fold whichever effect
    /// happened to slide into that position, which looks like a bug in the drag.
    private var collapsedEffects: Set<String> = []
    private(set) var effects: [EffectCardModel]

    /// Which graph slot a param code belongs to, so a Shift-click on a parameter's
    /// fader can arm a mapping without the panel knowing anything about MIDI.
    /// Set by the shell, which owns the slot tables.
    var mappingSlotForParameter: ((String, ParamCode) -> String?)? {
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
        if let key = view as? VBOptionButton,
           let (code, card) = Self.triggerAddress(key.identifier?.rawValue),
           let paramCode = ParamCode(rawValue: code) {
            key.mappingCode = paramCode
            key.mappingSlot = mappingSlotForParameter?(card, paramCode)
        }
        if let fader = view as? VBFader,
           let card = fader.ownerCard,
           let raw = fader.identifier?.rawValue,
           let code = ParamCode(rawValue: raw) {
            fader.mappingCode = code
            fader.mappingSlot = mappingSlotForParameter?(card, code)
        }
        for subview in view.subviews { refreshMappingAddresses(in: subview) }
    }

    /// Called after the card views are rebuilt, so their state can be restored.
    var onChainRebuilt: (() -> Void)?

    /// Called when a parameter fader moves: (card name, param code, new 0...1 value).
    var onParameterChanged: ((String, String, Double) -> Void)?

    /// Called when a parameter's reset key is pressed, with its param code.
    ///
    /// The VALUE is not carried, because the panel does not know it. A default belongs
    /// to the node that declares the parameter (`Parameter.defaultValue`), and the one
    /// in the card model is a display literal written out by hand in thirty-two places
    /// — resetting to that would slowly drift away from what the node actually does.
    var onParameterReset: ((String, String) -> Void)?

    /// A modulation badge on an effect header was clicked: (effect name, source,
    /// the badge view to hang a menu from).
    var onEffectModulationRequested: ((String, ModulationSource, NSView) -> Void)?

    /// The panel's FOCUS changed: 0 the first channel (A / C), 1 the second (B / D),
    /// 2 MIX — the sub-mix, after its crossfader. Every card edits that copy.
    var onFocusChanged: ((Int) -> Void)?

    /// FOCUS: three tall keys across the top of the panel — A · B · MIX (or C · D ·
    /// MIX). One control for the whole sheet (owner, 2026-09-28), replacing an A/B
    /// selector on every card. Keys, not a segmented control: they draw their own
    /// lit state in the focus yellow, which a segmented control cannot, and the
    /// owner asked for them to be prominent ("more prominent for A B MIX").
    private(set) var focusKeys: [VBOptionButton] = []
    private let focusRow = NSStackView()
    /// Which key is lit: 0, 1, or 2 (MIX).
    private(set) var focus = 0
    /// Position of MIX on the focus control.
    static let mixFocus = ChainEntry.both

    /// Called when an effect's enable switch is toggled: (effect name, on).
    var onEffectToggled: ((String, Bool) -> Void)?

    /// Called when the chain is reordered, with the new top-to-bottom name order.
    var onReordered: (([String]) -> Void)?

    /// Called when any fader in this panel gains or loses a sweep, so the controller
    /// can start or stop driving it.
    var onSweepsChanged: (() -> Void)?

    /// Called when an effect's ✕ is pressed.
    var onEffectRemoved: ((String) -> Void)?

    /// Called when a module is chosen from the Add menu, with its module ID.
    var onEffectAdded: ((String) -> Void)?

    /// One entry in the Add menu.
    struct AddMenuItem {
        let moduleID: String
        let title: String
        let isEnabled: Bool
        /// Why it cannot be added, for a greyed item.
        let tooltip: String?
    }

    /// A heading in the Add menu and what is under it.
    struct AddMenuGroup {
        let title: String
        let items: [AddMenuItem]
    }

    /// What the Add menu offers, grouped: Built-in, then each ISF category, then
    /// anything that failed to load, greyed with its reason. Set by the controller
    /// from the module catalogue; setting it rebuilds only the menu.
    var addMenuGroups: [AddMenuGroup] = [] {
        didSet { if let addPopUp { populateAddMenu(addPopUp) } }
    }

    private weak var addPopUp: NSPopUpButton?

    /// Each card's readout text per param code, from its parameters.
    private var valueTexts: [String: [String: EffectParameterModel]] = [:]

    init(effects: [EffectCardModel]) {
        self.effects = effects
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        // A flipped document view keeps the chain growing downward from the top.
        //
        // HELD, because a drag has to happen in THIS space. The cards live in it, it
        // scrolls, and it is the only one of the four views involved that agrees with
        // itself about which way y runs.
        let document = FlippedView()
        self.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // FOCUS keys first, then the pinned Source Controls card; both sit above the
        // scroll view, not in it, so nothing a drag or a scroll does can move them.
        focusRow.orientation = .horizontal
        focusRow.distribution = .fillEqually
        focusRow.spacing = 4
        focusRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusRow)
        // Empty, the Source Controls container takes no height.
        sourceContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceContainer)
        let emptyHeight = sourceContainer.heightAnchor.constraint(equalToConstant: 0)
        emptyHeight.priority = .defaultLow
        emptyHeight.isActive = true

        NSLayoutConstraint.activate([
            focusRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            focusRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            focusRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sourceContainer.topAnchor.constraint(equalTo: focusRow.bottomAnchor),
            sourceContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sourceContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: sourceContainer.bottomAnchor),
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
        // Only what is ACTUALLY in the stack. During a drag the lifted card is out of
        // it and a gap stands in its place, so `cardViews` no longer matches the
        // stack's contents — and `removeArrangedSubview` on a view that is not in the
        // stack throws, which aborted the app on every drop. Rebuilding from the
        // stack's own arranged subviews cannot get out of step with it.
        // Discarded, not just removed: the tooltip manager otherwise keeps every old
        // card alive (see NSView+Discard). Every card, including one lifted for a drag.
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.discardFromSuperview()
        }
        for view in cardViews { view.discardFromSuperview() }
        cardViews.removeAll()

        // Add / Save row at the top, above the layer stack. The Add popup lists what
        // has been removed, so ✕ is reversible rather than a one-way door.
        let addPopUp = Controls.popUp(
            [], target: self, action: #selector(addEffectChosen(_:)))
        addPopUp.identifier = NSUserInterfaceItemIdentifier("fx-add")
        addPopUp.setAccessibilityIdentifier("fx-add")
        addPopUp.toolTip = "Add an effect to this chain — built-in, or any ISF file you have imported"
        self.addPopUp = addPopUp
        populateAddMenu(addPopUp)
        let loadRow = Controls.row([
            addPopUp,
            Controls.button("Save", enabled: false)
        ], spacing: 3)
        stack.addArrangedSubview(loadRow)
        cardViews.append(loadRow)
        loadRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true

        valueTexts = [:]
        for effect in effects + [sourceCard].compactMap({ $0 }) {
            valueTexts[effect.name] = Dictionary(effect.parameters.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        }
        for (index, effect) in effects.enumerated() {
            let card = makeCard(effect, index: index)
            stack.addArrangedSubview(card)
            cardViews.append(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }

        onChainRebuilt?()
    }

    /// Builds one effect card.
    private func makeCard(_ effect: EffectCardModel, index: Int, isPinned: Bool = false) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        card.layer?.borderColor = Theme.Color.panelBorder.cgColor
        card.layer?.borderWidth = Theme.Metrics.hairline
        card.layer?.cornerRadius = Theme.Metrics.buttonCornerRadius

        // ---- Header: grip, name, enable, remove ----
        let grip = DragHandleView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onDragBegan = { [weak self] point in
            self?.beginDrag(of: index, at: point)
        }
        grip.onDrag = { [weak self] point in
            self?.previewReorder(of: index, to: point)
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

        // The three modulation sources, once per EFFECT rather than once per
        // parameter. Spelled out, because "M S C" reads as Mute/Solo/... to anyone
        // who has used an audio mixer — and this app has no mute and no solo. They
        // were also a column of decoration on every parameter row, repeated five or
        // six times down a card that is already narrow.
        //
        // Individual parameters are still individually mappable: hold Shift and click
        // any fader. That gesture arrived after these badges did and quietly made the
        // per-parameter column redundant.
        // The selector does NOT go in the header. Three segments beside a grip, a
        // name, a switch and a close button collapsed the effect's name to an
        // ellipsis in a column this narrow — and a card you cannot identify is worse
        // than one whose selector costs a row. It joins the badges on the line below,
        // which is already there and has room.
        // The gap between the name and the switch was a plain spacer doing nothing but
        // pushing the switch right. It is the largest quiet target on the card, so it
        // folds the effect instead.
        let collapseStrip = CollapseStripView()
        collapseStrip.isCollapsed = collapsedEffects.contains(effect.name)
        collapseStrip.toolTip = collapsedEffects.contains(effect.name)
            ? "Show \(effect.name)'s controls"
            : "Hide \(effect.name)'s controls — the effect keeps running"
        collapseStrip.onClick = { [weak self] in
            self?.toggleCollapsed(effect.name)
        }

        // A pinned card has no grip, switch or ✕: it cannot be reordered, bypassed or
        // taken out, so offering the controls for it would be offering nothing.
        var headerViews: [NSView] = isPinned ? [nameLabel] : [grip, nameLabel]
        headerViews.append(collapseStrip)
        if !effect.isImplemented {
            let note = Controls.label("not built", font: Theme.Font.tinyLabel,
                                      color: Theme.Color.textTertiary)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(note)
        }
        if !isPinned {
            headerViews.append(enableSwitch)
            headerViews.append(removeButton)
        }
        let header = Controls.row(headerViews, spacing: 4)

        // The badges get their own line. Spelled-out names do not fit beside a grip,
        // a name, a switch and a close button in a column this narrow — the first
        // attempt truncated LFO to "L…", which is exactly the failure that made the
        // single letters ambiguous in the first place. A line of their own costs one
        // row and keeps the words whole.
        var modulationRow: NSView?
        if effect.isImplemented {
            var badges: [NSView] = []
            // The effect-wide badges drive an effect's wet/dry, which a source does not
            // have. Its faders are still learnable one by one with Shift-click.
            for source in ModulationSource.allCases where !isPinned {
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
            // Where the module came from, at the far end of the row it shares with
            // the badges — the header has no room left, and the name must not be what
            // gets cut.
            if let badge = effect.badge {
                let origin = Controls.label(badge, font: Theme.Font.tinyLabel,
                                            color: Theme.Color.textTertiary, holdsWidth: true)
                origin.identifier = NSUserInterfaceItemIdentifier("origin|\(effect.name)")
                badges.append(origin)
            }
            modulationRow = Controls.row(badges, spacing: 3)
        }

        // ---- Status: compiling, or why it is not running ----
        let status = Controls.label(effect.status ?? "", font: Theme.Font.tinyLabel,
                                    color: Theme.Color.moduleProblem)
        status.identifier = NSUserInterfaceItemIdentifier("status|\(effect.name)")
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.toolTip = effect.status
        status.isHidden = effect.status == nil

        // ---- Parameters: two lines each ----
        var rows: [NSView] = [header]
        if let modulationRow { rows.append(modulationRow) }
        if let subtitleText = effect.subtitle {
            let subtitle = Controls.label(subtitleText, font: Theme.Font.tinyLabel,
                                          color: Theme.Color.textSecondary)
            subtitle.identifier = NSUserInterfaceItemIdentifier("subtitle|\(effect.name)")
            subtitle.lineBreakMode = .byTruncatingTail
            subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitle.toolTip = effect.subtitleDetail ?? subtitleText
            rows.append(subtitle)
        }
        rows.append(status)
        // Adjacent triggers share ONE row of keys (MOSH beside HEAL): a pad row the
        // hand finds as a unit, and a key added next to an existing one moves
        // nothing below it on the card.
        var pendingTriggers: [EffectParameterModel] = []
        for parameter in effect.parameters {
            if parameter.isTrigger {
                pendingTriggers.append(parameter)
                continue
            }
            if !pendingTriggers.isEmpty {
                rows.append(makeTriggerRow(pendingTriggers, card: effect.name))
                pendingTriggers = []
            }
            rows.append(contentsOf: makeParameterRows(parameter, card: effect.name))
        }
        if !pendingTriggers.isEmpty { rows.append(makeTriggerRow(pendingTriggers, card: effect.name)) }

        // Collapsing hides everything below the header. The header stays because it
        // carries the switch and the ✕ — a folded effect must still be reachable
        // without being unfolded first, or folding costs more than it saves.
        if collapsedEffects.contains(effect.name) {
            for row in rows.dropFirst() { row.isHidden = true }
        }
        if !collapsedEffects.contains(effect.name) { status.isHidden = effect.status == nil }

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

    /// The readout's width: the standard one, or wider when the parameter's labels
    /// need it ("screen", "5.00 s"). Measured over the whole travel, so it is fixed
    /// for the row and never twitches as the value changes.
    private static func readoutWidth(for parameter: EffectParameterModel) -> CGFloat {
        guard parameter.valueText != nil else { return Theme.Metrics.valueReadoutWidth }
        var widest: CGFloat = 0
        for step in 0...64 {
            let text = parameter.text(for: Double(step) / 64) as NSString
            widest = max(widest, text.size(withAttributes: [.font: Theme.Font.mono]).width)
        }
        return max(Theme.Metrics.valueReadoutWidth, ceil(widest) + 2)
    }

    /// A trigger key's identifier: "trigger|<code>|<card>".
    private static func triggerIdentifier(code: String, card: String) -> String {
        "trigger|\(code)|\(card)"
    }

    /// The code and card a trigger key's identifier names, or nil for anything else.
    private static func triggerAddress(_ identifier: String?) -> (code: String, card: String)? {
        guard let parts = identifier?.split(separator: "|", maxSplits: 2).map(String.init),
              parts.count == 3, parts[0] == "trigger" else { return nil }
        return (parts[1], parts[2])
    }

    /// One line for a run of triggers: their names and codes, then a key for each,
    /// right-aligned in catalog order.
    ///
    /// KEYS, not faders. A trigger does one thing when it is pressed; a fader for it
    /// read as a level ("heal 0.62?") and had to be dragged across halfway and back
    /// to fire twice. Each key is a pad: on while held, and it learns a MIDI note with
    /// Shift-click like CUT and FADE do.
    private func makeTriggerRow(_ triggers: [EffectParameterModel], card: String) -> NSView {
        let enabled = triggers.contains(where: \.enabled)
        // One key: its name and code, like every other row. Several: the keys carry
        // the names, so the label is just their codes in key order — the part a
        // mapping needs, and short enough not to truncate beside two keys.
        let text = triggers.count == 1
            ? "\(triggers[0].name)·\(triggers[0].code)"
            : triggers.map(\.code).joined(separator: " ")
        let label = Controls.monoLabel(
            text, color: enabled ? Theme.Color.textSecondary : Theme.Color.textTertiary)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keys = triggers.map { makeTriggerKey($0, card: card) }
        return Controls.row([label, Controls.spacer()] + keys, spacing: 5)
    }

    /// One trigger's key.
    private func makeTriggerKey(_ parameter: EffectParameterModel, card: String) -> VBOptionButton {
        let key = VBOptionButton(title: parameter.name.uppercased(), onColour: Theme.Color.accent)
        key.isMomentary = true
        key.isTall = true
        key.isEnabled = parameter.enabled
        key.target = self
        key.action = #selector(triggerPressed(_:))
        key.identifier = NSUserInterfaceItemIdentifier(Self.triggerIdentifier(code: parameter.code, card: card))
        key.toolTip = (parameter.help.map { $0 + "\n\n" } ?? "")
            + "\(parameter.name.capitalized) · \(parameter.code) — hold Shift and click to learn a MIDI note"
        if let code = ParamCode(rawValue: parameter.code) {
            key.mappingCode = code
            key.mappingSlot = mappingSlotForParameter?(card, code)
        }
        if let arm = parameter.beatArm {
            key.toolTip = (key.toolTip ?? "")
                + ". Option-Command-click to fire it on the beat, at the rate "
                + "\(valueTexts[card]?[arm.code]?.name ?? arm.code) sets; again to stop"
            key.isArmedOnBeat = arm.isArmed(valueTexts[card]?[arm.code]?.value ?? 0)
            key.onBeatArmToggled = { [weak self] in
                self?.toggleBeatArm(trigger: parameter.code, card: card)
            }
        }
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metrics.triggerKeyMinWidth).isActive = true
        return key
    }

    /// The rate each armed trigger last had, by "card|trigger code", so disarming and
    /// arming again comes back at the rate the performer chose rather than the default.
    private var lastBeatArmValue: [String: Double] = [:]

    /// Option-Command-click on a trigger key: flips the choice that fires it on the
    /// beat between off and a rate.
    ///
    /// Goes through the choice's own FADER, exactly as a drag would — so its readout,
    /// the registry, a saved template and a MIDI mapping on it all see the same value
    /// — and the key's outline then follows the fader (`refreshBeatArmedKeys`).
    private func toggleBeatArm(trigger: String, card: String) {
        guard let arm = valueTexts[card]?[trigger]?.beatArm,
              let index = effects.firstIndex(where: { $0.name == card }),
              cardViews.indices.contains(index + 1) else { return }
        guard let fader = allSubviews(of: cardViews[index + 1])
            .compactMap({ $0 as? VBFader })
            .first(where: { $0.identifier?.rawValue == arm.code }) else {
            Log.warn(.app, "\(card): no \(arm.code) fader to arm \(trigger) on the beat")
            return
        }
        let memory = "\(card)|\(trigger)"
        if arm.isArmed(fader.value) {
            lastBeatArmValue[memory] = fader.value
            // The choice's first position is "off" (ModuleBeatArm).
            fader.value = 0
        } else {
            fader.value = lastBeatArmValue[memory] ?? arm.armedValue
        }
        faderMoved(fader)
        Log.info(.app, "\(card): \(trigger) \(arm.isArmed(fader.value) ? "armed" : "disarmed") on the beat")
    }

    /// Lights the automated outline on each trigger key whose beat choice is on.
    /// Called whenever a card's values change for any reason — a drag, ⌥⌘-click,
    /// a reset, a channel switch — so the outline can never disagree with the fader.
    private func refreshBeatArmedKeys(card: String) {
        guard let models = valueTexts[card],
              let index = effects.firstIndex(where: { $0.name == card }),
              cardViews.indices.contains(index + 1) else { return }
        let views = allSubviews(of: cardViews[index + 1])
        for case let key as VBOptionButton in views {
            guard let (code, _) = Self.triggerAddress(key.identifier?.rawValue),
                  let arm = models[code]?.beatArm,
                  let fader = views.compactMap({ $0 as? VBFader })
                    .first(where: { $0.identifier?.rawValue == arm.code }) else { continue }
            key.isArmedOnBeat = arm.isArmed(fader.value)
        }
    }

    /// The two lines for one parameter: badges/name/value, then a full-width fader.
    private func makeParameterRows(_ parameter: EffectParameterModel, card: String) -> [NSView] {
        if parameter.isTrigger { return [makeTriggerRow([parameter], card: card)] }
        // Line 1 — name with its param code, and the current value. No badge column:
        // it said the same three things on every row of every card, and Shift-click
        // maps a parameter without needing a control of its own.
        let label = Controls.monoLabel(
            "\(parameter.name)·\(parameter.code)",
            color: parameter.enabled ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        label.toolTip = parameter.help
        // Fixed width, so the row does not twitch as the digits change under a drag,
        // and so the readout is never what gets truncated when the column is narrow.
        let value = Controls.monoLabel(parameter.text(for: parameter.value))
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(
            equalToConstant: Self.readoutWidth(for: parameter)).isActive = true
        value.identifier = NSUserInterfaceItemIdentifier("value|\(parameter.code)")

        // The sweep's rate key, to the LEFT of the value, and only once a sweep is
        // armed. A rate control on a fader with no marks would be a control for
        // nothing, on the narrowest rows in the window.
        let sweepKey = VBStepButton()
        sweepKey.allowsOff = false       // a rate key never walks to off (VBStepButton)
        sweepKey.isHidden = true
        sweepKey.toolTip = "How long one sweep between the marks takes"

        // Cancelling a sweep needs its own control. Command-option clicking a third
        // time re-aims rather than clears, which is right for re-aiming and useless
        // for stopping — and a drive you cannot switch off is worse than one you
        // cannot start.
        let sweepCancel = Controls.glyphButton("✕", tooltip: "Stop this fader driving itself")
        sweepCancel.isHidden = true

        // RESET, next to the title. A parameter you have pushed somewhere odd mid-set
        // needs a way back that is not "remember what it used to be", and every one of
        // these already declares a default — the node that owns the parameter says what
        // it is. The circular arrow is the ordinary symbol for it and costs one glyph
        // of a narrow row.
        //
        // Disabled along with its parameter: a reset key on a control whose feature is
        // not built would be a control that looks usable and does nothing, which the
        // control audit fails the build over.
        let resetKey = Controls.glyphButton(
            "↺", enabled: parameter.enabled,
            tooltip: "Reset \(parameter.name) to its default",
            target: self, action: #selector(parameterResetPressed(_:)))
        resetKey.identifier = NSUserInterfaceItemIdentifier("reset|\(parameter.code)|\(card)")

        let topLine = Controls.row(
            [label, resetKey, Controls.spacer(), sweepKey, sweepCancel, value], spacing: 5)

        // Line 2 — the fader, full width. This is the whole reason for two lines.
        let fader = Controls.fader(
            value: parameter.value, enabled: parameter.enabled,
            target: self, action: #selector(faderMoved(_:))
        )
        fader.identifier = NSUserInterfaceItemIdentifier(parameter.code)
        fader.toolTip = parameter.help
        fader.ownerCard = card
        if let code = ParamCode(rawValue: parameter.code) {
            fader.mappingCode = code
            fader.mappingSlot = mappingSlotForParameter?(card, code)
        }

        // The key drives the fader's rate; the fader's marks decide whether the key
        // is there at all. Each owns one half so neither has to ask the other.
        sweepKey.onTimingChanged = { [weak fader] timing in
            fader?.sweepRate = timing
        }
        sweepKey.setTiming(fader.sweepRate)
        sweepCancel.target = fader
        sweepCancel.action = #selector(VBFader.clearSweep)
        fader.onSweepChanged = { [weak self, weak fader, weak sweepKey, weak sweepCancel] in
            guard let fader else { return }
            let armed = fader.sweep != nil
            sweepKey?.isHidden = !armed
            sweepCancel?.isHidden = !armed
            // The rate can change without the key (a saved show, a template): show it.
            sweepKey?.setTiming(fader.sweepRate)
            self?.onSweepsChanged?()
        }

        return [topLine, fader]
    }

    // MARK: - Reordering

    /// Offset applied to the dragged card while the drag is in progress.
    /// Everything a drag needs, alive only while one is happening.
    ///
    /// One struct rather than four optionals, because they are only ever valid
    /// together — the old version kept a `draggingIndex` and a `pendingOrder` that
    /// could disagree, and a half-finished drag left one of them set.
    private struct DragState {
        /// Where the card started in the chain.
        let sourceIndex: Int
        /// The card being moved, kept out of the stack while it floats.
        let card: NSView
        /// Its height, so the gap that stands in for it is the right size.
        let height: CGFloat
        /// The snapshot that follows the pointer.
        let floater: CALayer
        /// How far down the card the pointer grabbed it, so it does not jump.
        let grabOffset: CGFloat
        /// The empty view standing in for the card at its current target.
        let gap: NSView
        /// Where it would land if dropped now.
        var targetIndex: Int
    }

    private var drag: DragState?

    /// The flipped, scrolling view the cards live in. Every drag measurement is in
    /// its coordinate space.
    private weak var documentView: NSView?

    /// Moves the dragged card past its neighbours as the pointer travels.
    ///
    /// Cards are a similar height, so a drag of roughly one card height means one
    /// position. Measuring the actual neighbour heights would be more precise, but a
    /// chain of near-identical rows does not need it.
    // MARK: - Reordering
    //
    // ── WHY THIS IS NOT A LIST THAT REBUILDS ────────────────────────────────────
    //
    // The first version stepped the order by `offset / 46` — a HARD-CODED card height
    // — and called `rebuild()` on every step. Cards are not 46 points tall; Transform
    // has four parameters and the composite stage has nine, so the guess was wrong by
    // a factor of three at the bottom of the chain. And rebuilding tears down every
    // view in the panel mid-drag, which is why it felt like fighting it.
    //
    // Nothing rebuilds during a drag now. The card is LIFTED out of the stack into a
    // floating layer that follows the pointer; an empty view of the same height takes
    // its place and moves between positions; the rest of the list dims so the thing
    // being moved is the only thing at full contrast. The order is committed once, at
    // the end.
    //
    // ── ON APPKIT'S OWN ANSWER ──────────────────────────────────────────────────
    //
    // There is one: an `NSTableView` in view-based mode with `pasteboardWriterForRow`
    // and `acceptDrop` gives the lift, the gap and the drop indicator for free, and
    // keyboard reordering and accessibility with it. It is the right destination.
    //
    // It is not what this is, because these rows are tall, variable-height views full
    // of live controls, and a table wants to own their heights and their reuse. The
    // interaction below is the same interaction; moving it into a table later changes
    // this file and nothing else.

    /// Lifts a card out of the chain and starts following the pointer.
    private func beginDrag(of index: Int, at windowPoint: NSPoint) {
        guard drag == nil,
              let document = documentView,
              let card = cardView(at: index) else { return }

        // EVERYTHING below is in the document's space: the card's frame, the floating
        // layer, the pointer, and the comparisons that decide where it lands. The first
        // version mixed three spaces — the card's frame from the stack, the layer on
        // the panel, and an offset measured in an unflipped subview — so the card
        // appeared in the wrong place and the gap moved the opposite way to the hand.
        let frame = document.convert(card.bounds, from: card)
        let pointer = document.convert(windowPoint, from: nil)

        let floater = CALayer()
        floater.contents = snapshot(of: card)
        floater.contentsScale = window?.backingScaleFactor ?? 2
        floater.frame = frame
        floater.cornerRadius = Theme.Metrics.buttonCornerRadius
        floater.shadowColor = NSColor.black.cgColor
        floater.shadowOpacity = 0.5
        floater.shadowRadius = 10
        floater.shadowOffset = CGSize(width: 0, height: 2)
        floater.zPosition = 100
        document.wantsLayer = true
        document.layer?.addSublayer(floater)

        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.heightAnchor.constraint(equalToConstant: frame.height).isActive = true

        stack.removeArrangedSubview(card)
        card.removeFromSuperview()
        stack.insertArrangedSubview(gap, at: stackIndex(forCard: index))
        gap.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true

        // LAY OUT NOW. A freshly inserted view has no frame until the next pass, so
        // without this the very first measurement compares the pointer against a gap
        // sitting at the bottom of the document and every card at its pre-drag
        // position — and the insertion point comes out as "no change", every time.
        document.layoutSubtreeIfNeeded()

        drag = DragState(
            sourceIndex: index, card: card, height: frame.height,
            floater: floater,
            // WHERE IN THE CARD it was grabbed, so the card does not jump so that its
            // top-left snaps to the pointer the moment the drag starts.
            grabOffset: pointer.y - frame.minY,
            gap: gap, targetIndex: index)

        setListDimmed(true)
    }

    /// Moves the floating card and the gap as the pointer travels.
    private func previewReorder(of index: Int, to windowPoint: NSPoint) {
        guard let document = documentView else { return }
        guard var state = drag else {
            beginDrag(of: index, at: windowPoint)
            return
        }

        let pointer = document.convert(windowPoint, from: nil)

        // The floater tracks the pointer exactly. No animation — it IS the pointer, and
        // lag between the two is the single thing that makes a drag feel broken.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        state.floater.frame.origin.y = pointer.y - state.grabOffset
        CATransaction.commit()

        // Where it would land: measured against the REAL card frames, in the same
        // space, rather than against an assumed row height.
        let centre = state.floater.frame.midY
        let target = insertionIndex(forCentre: centre, excluding: state.gap, in: document)
        guard target != state.targetIndex else {
            drag = state
            return
        }

        state.targetIndex = target
        drag = state

        // The gap moves, animated, so the list opens and closes under the card.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            stack.removeArrangedSubview(state.gap)
            stack.insertArrangedSubview(state.gap, at: stackIndex(forCard: target))
            document.layoutSubtreeIfNeeded()
        }
    }

    /// Drops the card, commits the order, and tells the app.
    private func commitReorder() {
        guard let state = drag else { return }
        drag = nil
        setListDimmed(false)

        let from = state.sourceIndex
        let to = state.targetIndex

        // Settle the floater into the gap before it disappears, so the card arrives
        // rather than teleports. In the DOCUMENT's space, like everything else in this
        // drag — the gap's own frame is in the stack's.
        let landing = documentView.map { $0.convert(state.gap.bounds, from: state.gap) }
            ?? state.gap.frame
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            state.floater.removeFromSuperlayer()
            self?.rebuild()
        }
        let move = CABasicAnimation(keyPath: "position")
        move.duration = 0.16
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        state.floater.frame = landing
        state.floater.add(move, forKey: "land")
        CATransaction.commit()

        guard to != from, effects.indices.contains(from) else {
            rebuild()
            return
        }

        var reordered = effects
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: min(to, reordered.count))
        effects = reordered

        // ORDER IS PROCESSING ORDER. The chain runs top to bottom, so moving a card is
        // not a cosmetic sort — it changes what each effect receives. The graph is told
        // once, here, rather than on every step of the drag.
        Log.info(.graph, "effect chain reordered: \(effects.map(\.name).joined(separator: " → "))")
        onReordered?(effects.map(\.name))
    }

    /// The card view for an effect index, if it is in the stack.
    private func cardView(at index: Int) -> NSView? {
        let position = stackIndex(forCard: index)
        guard stack.arrangedSubviews.indices.contains(position) else { return nil }
        return stack.arrangedSubviews[position]
    }

    /// Where a card sits in the stack, which is offset by the Add/Save row above it.
    private func stackIndex(forCard index: Int) -> Int {
        index + 1
    }

    /// Which slot a card dropped at this height would take.
    private func insertionIndex(
        forCentre centre: CGFloat, excluding gap: NSView, in document: NSView
    ) -> Int {
        var slot = 0
        for view in stack.arrangedSubviews.dropFirst() where view !== gap {
            // Converted, so a card's midpoint and the floater's are measured the same
            // way. Comparing a stack-space frame against a document-space centre is
            // what made the insertion point drift as you scrolled.
            let midY = document.convert(view.bounds, from: view).midY
            if centre < midY { break }
            slot += 1
        }
        return min(max(slot, 0), max(effects.count - 1, 0))
    }

    /// Dims everything except the card being moved.
    ///
    /// The point of the dim is not decoration: it says which thing the gesture is
    /// about. With every card at full contrast, a lifted card is one more card.
    private func setListDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            for view in stack.arrangedSubviews {
                view.alphaValue = dimmed ? 0.45 : 1
            }
        }
    }

    /// A bitmap of a card, for the thing that follows the pointer.
    private func snapshot(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Actions

    /// A card's model and view by name — the pinned Source Controls card, or one in
    /// the chain.
    private func card(named name: String) -> (model: EffectCardModel, view: NSView)? {
        if let sourceCard, sourceCard.name == name, let view = sourceCardView {
            return (sourceCard, view)
        }
        guard let index = effects.firstIndex(where: { $0.name == name }),
              cardViews.indices.contains(index + 1) else { return nil }
        return (effects[index], cardViews[index + 1])
    }

    /// The pinned card's view, for checks that assert it stays put.
    var sourceCardViewForChecks: NSView? { sourceCardView }

    /// Rebuilds only the pinned card: a channel changing source must not reset the
    /// chain's scroll position or a drag in progress.
    private func rebuildSourceCard() {
        sourceCardView?.discardFromSuperview()
        sourceCardView = nil
        guard let sourceCard else { return }
        valueTexts[sourceCard.name] = Dictionary(
            sourceCard.parameters.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let view = makeCard(sourceCard, index: -1, isPinned: true)
        view.translatesAutoresizingMaskIntoConstraints = false
        sourceContainer.addSubview(view)
        // Inset to line up with the chain's cards below (the stack's 4pt edges).
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: sourceContainer.topAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: sourceContainer.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: sourceContainer.trailingAnchor, constant: -4),
            view.bottomAnchor.constraint(equalTo: sourceContainer.bottomAnchor)
        ])
        sourceCardView = view
        onChainRebuilt?()
    }

    @objc private func faderMoved(_ sender: VBFader) {
        guard let code = sender.identifier?.rawValue, let card = sender.ownerCard else { return }
        // Update the readout on the line above — on THIS card: another card can use
        // the same code.
        if let view = self.card(named: card)?.view {
            let identifier = NSUserInterfaceItemIdentifier("value|\(code)")
            for case let field as NSTextField in allSubviews(of: view)
            where field.identifier == identifier {
                field.stringValue = valueTexts[card]?[code]?.text(for: sender.value) ?? String(format: "%.2f", sender.value)
            }
        }
        onParameterChanged?(card, code, sender.value)
        refreshBeatArmedKeys(card: card)
    }

    /// A trigger key went down (1) or came up (0).
    @objc private func triggerPressed(_ sender: VBOptionButton) {
        guard let (code, card) = Self.triggerAddress(sender.identifier?.rawValue) else { return }
        onParameterChanged?(card, code, sender.isOn ? 1 : 0)
    }

    /// A badge on an effect's header. Reports the effect name and the source's
    /// internal letter, which is what the engine and the saved templates key off.
    @objc private func effectBadgeClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let source = ModulationSource.fromBadge(parts[1]) else { return }
        onEffectModulationRequested?(parts[0], source, sender)
    }

    /// Sends a parameter back to the default its node declares.
    @objc private func parameterResetPressed(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let parts = identifier.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "reset" else { return }
        onParameterReset?(parts[2], parts[1])
    }

    /// Folds an effect down to its header, or opens it again.
    ///
    /// COLLAPSING IS NOT DISABLING, and keeping those apart is the whole point of
    /// putting this on the gap rather than on the name: the switch beside it turns the
    /// effect OFF, this only puts its controls away. A collapsed effect is still
    /// running, still processing, and still shows its switch lit.
    private func toggleCollapsed(_ name: String) {
        if collapsedEffects.contains(name) {
            collapsedEffects.remove(name)
        } else {
            collapsedEffects.insert(name)
        }
        Log.info(.app, "\(name) \(collapsedEffects.contains(name) ? "collapsed" : "expanded")")
        if name == Self.sourceCardName { rebuildSourceCard() } else { rebuild() }
    }

    /// Whether an effect is folded. For the self-QA harness, which cannot click.
    func isCollapsed(effectName: String) -> Bool {
        collapsedEffects.contains(effectName)
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectToggled?(name, sender.state == .on)
    }

    /// Builds the focus keys for this panel's channels: A · B · MIX or C · D · MIX.
    func configureFocus(channels: [String]) {
        for key in focusKeys { focusRow.removeArrangedSubview(key); key.removeFromSuperview() }
        let names = channels + ["MIX"]
        focusKeys = names.enumerated().map { index, name in
            let key = VBOptionButton(title: name, onColour: Theme.Color.focusOn)
            key.isTall = true
            key.tag = index
            key.target = self
            key.action = #selector(focusKeyPressed(_:))
            key.toolTip = index < channels.count
                ? "Show and edit \(name)'s effects, before the crossfader"
                : "Show and edit the \(channels.joined(separator: "/")) sub-mix's effects, after its crossfader"
            key.setAccessibilityLabel("Effects focus \(name)")
            key.setAccessibilityIdentifier("fx-focus-\(name)")
            focusRow.addArrangedSubview(key)
            return key
        }
        focusRow.toolTip = "Which effects this panel shows and edits. Nothing on air changes; "
            + "each keeps its own settings."
        showFocus()
    }

    /// Shows a focus without reporting it (launch, a loaded show).
    func setFocus(_ index: Int) {
        focus = max(0, min(index, focusKeys.count - 1))
        showFocus()
    }

    /// Picks a focus the way a click does — for self-QA.
    func pickFocusForChecks(_ index: Int) {
        guard focusKeys.indices.contains(index) else { return }
        focusKeyPressed(focusKeys[index])
    }

    private func showFocus() {
        for key in focusKeys {
            key.isOn = key.tag == focus
            key.needsDisplay = true
        }
    }

    /// Radio: the pressed key lights and the others go out. Pressing the lit key
    /// leaves it lit — there is always a focus.
    @objc private func focusKeyPressed(_ sender: VBOptionButton) {
        let picked = sender.tag
        let changed = picked != focus
        focus = picked
        showFocus()
        if changed { onFocusChanged?(focus) }
    }

    /// Pushes new values into a specific card's parameter faders and readouts, for
    /// when what the card should show changed for a reason other than a drag on the
    /// fader itself — here, its channel selector pointing somewhere else.
    ///
    /// Targeted rather than a full `rebuild()`: rebuilding would also reset scroll
    /// position and drop the in-flight drag-reorder state, for a change that is only
    /// ever "this fader's number is now different."
    func setDisplayedParameterValues(effectName: String, values: [String: Double]) {
        guard let card = card(named: effectName)?.view else { return }

        for (code, value) in values {
            for case let fader as VBFader in allSubviews(of: card)
            where fader.identifier?.rawValue == code {
                fader.value = value
            }
            for case let label as NSTextField in allSubviews(of: card)
            where label.identifier?.rawValue == "value|\(code)" {
                label.stringValue = valueTexts[effectName]?[code]?.text(for: value) ?? String(format: "%.2f", value)
            }
        }
        refreshBeatArmedKeys(card: effectName)
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
        // Item 0 is the prompt; headings carry no module.
        guard let moduleID = sender.selectedItem?.representedObject as? String else { return }
        sender.selectItem(at: 0)
        onEffectAdded?(moduleID)
    }

    /// Fills the Add menu: a prompt, then each group's heading and its modules.
    private func populateAddMenu(_ popUp: NSPopUpButton) {
        popUp.removeAllItems()
        popUp.addItem(withTitle: "Add effect…")
        popUp.menu?.autoenablesItems = false
        for group in addMenuGroups where !group.items.isEmpty {
            popUp.menu?.addItem(.separator())
            let heading = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            popUp.menu?.addItem(heading)
            for item in group.items {
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.representedObject = item.moduleID
                entry.isEnabled = item.isEnabled
                entry.indentationLevel = 1
                entry.toolTip = item.tooltip
                popUp.menu?.addItem(entry)
            }
        }
        popUp.isEnabled = addMenuGroups.contains { $0.items.contains(where: \.isEnabled) }
        popUp.selectItem(at: 0)
    }

    /// Replaces the cards, keeping each card's fold by name.
    /// For when the chain itself changed — an effect added or removed.
    func setEffects(_ newEffects: [EffectCardModel]) {
        effects = newEffects
        let names = Set(newEffects.map(\.name) + [Self.sourceCardName])
        collapsedEffects = collapsedEffects.filter { names.contains($0) }
        rebuild()
    }

    /// Updates one card's status line in place ("compiling…" → nothing), without a
    /// rebuild, which would reset scrolling and a drag in progress.
    func setStatus(effectName: String, status: String?) {
        guard let index = effects.firstIndex(where: { $0.name == effectName }),
              cardViews.indices.contains(index + 1) else { return }
        let current = effects[index]
        guard current.status != status else { return }
        var updated = current
        updated.status = status
        effects[index] = updated
        let identifier = NSUserInterfaceItemIdentifier("status|\(effectName)")
        for case let label as NSTextField in allSubviews(of: cardViews[index + 1]) where label.identifier == identifier {
            label.stringValue = status ?? ""
            label.toolTip = status
            label.isHidden = status == nil || collapsedEffects.contains(effectName)
        }
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
