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

    /// The readout for a fader position.
    func text(for value: Double) -> String {
        valueText?(value) ?? String(format: "%.2f", value)
    }
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
    /// Channel letters this card can target, e.g. ["A", "B"]. Empty means the card
    /// has exactly one target and no selector is drawn.
    ///
    /// This exists because SPEC 2's chFX runs once per CHANNEL, not once per bus —
    /// A and B each carry their own bitstream wedge — but the panel only has room to
    /// show one card's worth of controls at a time. The selector is what lets one
    /// card reach either channel rather than the card being hardwired to whichever
    /// channel got there first.
    var channelOptions: [String] = []
    /// Where the selector starts: an index into `channelOptions`, or one past the
    /// end for BOTH. Must match what the controller routes to at launch.
    var initialChannelIndex = 0
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

    /// A card's channel selector changed: (effect name, index into its
    /// `channelOptions`).
    var onCardChannelChanged: ((String, Int) -> Void)?

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

    /// Which channel each channel-selecting card is currently pointed at, by effect
    /// name. Kept here rather than in `EffectCardModel` so a rebuild (reordering,
    /// enabling) does not reset a choice the performer just made.
    private var cardChannelSelection: [String: Int] = [:]

    init(effects: [EffectCardModel]) {
        self.effects = effects
        for effect in effects where effect.initialChannelIndex != 0 {
            cardChannelSelection[effect.name] = effect.initialChannelIndex
        }
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
        // Only what is ACTUALLY in the stack. During a drag the lifted card is out of
        // it and a gap stands in its place, so `cardViews` no longer matches the
        // stack's contents — and `removeArrangedSubview` on a view that is not in the
        // stack throws, which aborted the app on every drop. Rebuilding from the
        // stack's own arranged subviews cannot get out of step with it.
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in cardViews where view.superview != nil { view.removeFromSuperview() }
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
        for effect in effects {
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

        // The channel selector, for chFX cards — an effect that runs once per
        // CHANNEL (SPEC 2) rather than once per bus, where the panel only has room
        // for one card's worth of controls. Small and in the same family as the
        // A/B · C/D toggle on the libraries, so it reads as the same kind of choice.
        var channelSelector: NSSegmentedControl?
        if effect.channelOptions.count > 1 {
            // Three STATES, two segments. Clicking past the last channel selects
            // BOTH, and both segments light rather than a third segment appearing —
            // a word that says "both" takes more width than the two things it is
            // describing, in the narrowest column in the window.
            let selected = cardChannelSelection[effect.name] ?? 0
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

        var headerViews: [NSView] = [grip, nameLabel]
        headerViews.append(collapseStrip)
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
            if let channelSelector {
                badges.append(channelSelector)
                // A gap, or BOTH runs straight into MIDI and the two controls read as
                // one run-on string.
                let gap = NSView()
                gap.translatesAutoresizingMaskIntoConstraints = false
                gap.widthAnchor.constraint(equalToConstant: 8).isActive = true
                badges.append(gap)
            }
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
        rows.append(status)
        for parameter in effect.parameters {
            rows.append(contentsOf: makeParameterRows(parameter, card: effect.name))
        }

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

    /// The two lines for one parameter: badges/name/value, then a full-width fader.
    private func makeParameterRows(_ parameter: EffectParameterModel, card: String) -> [NSView] {
        // Line 1 — name with its param code, and the current value. No badge column:
        // it said the same three things on every row of every card, and Shift-click
        // maps a parameter without needing a control of its own.
        let label = Controls.monoLabel(
            "\(parameter.name)·\(parameter.code)",
            color: parameter.enabled ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        // Fixed width, so the row does not twitch as the digits change under a drag,
        // and so the readout is never what gets truncated when the column is narrow.
        let value = Controls.monoLabel(parameter.text(for: parameter.value))
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(
            equalToConstant: Theme.Metrics.valueReadoutWidth).isActive = true
        value.identifier = NSUserInterfaceItemIdentifier("value|\(parameter.code)")

        // The sweep's rate key, to the LEFT of the value, and only once a sweep is
        // armed. A rate control on a fader with no marks would be a control for
        // nothing, on the narrowest rows in the window.
        let sweepKey = VBStepButton()
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

    @objc private func faderMoved(_ sender: VBFader) {
        guard let code = sender.identifier?.rawValue, let card = sender.ownerCard else { return }
        // Update the readout on the line above — on THIS card: another card can use
        // the same code.
        if let index = effects.firstIndex(where: { $0.name == card }), cardViews.indices.contains(index + 1) {
            let identifier = NSUserInterfaceItemIdentifier("value|\(code)")
            for case let field as NSTextField in allSubviews(of: cardViews[index + 1])
            where field.identifier == identifier {
                field.stringValue = valueTexts[card]?[code]?.text(for: sender.value) ?? String(format: "%.2f", sender.value)
            }
        }
        onParameterChanged?(card, code, sender.value)
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
        rebuild()
    }

    /// Whether an effect is folded. For the self-QA harness, which cannot click.
    func isCollapsed(effectName: String) -> Bool {
        collapsedEffects.contains(effectName)
    }

    /// Folds or opens every effect at once.
    ///
    /// Not on a control yet. It exists because "collapse all" is the first thing
    /// anyone asks for after collapsing three cards by hand, and having it here means
    /// the answer is a menu item rather than a rewrite.
    func setAllCollapsed(_ collapsed: Bool) {
        collapsedEffects = collapsed ? Set(effects.map(\.name)) : []
        rebuild()
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let name = sender.identifier?.rawValue else { return }
        onEffectToggled?(name, sender.state == .on)
    }

    /// Paints the selector for a state, where a state past the last segment is BOTH.
    ///
    /// BOTH lights every segment in the focus orange rather than selecting one. The
    /// segmented control has no "all selected" mode, so the state lives in
    /// `cardChannelSelection` and this is what makes it visible.
    private func restyleFocus(_ control: NSSegmentedControl, options: [String], state: Int) {
        let isBoth = state >= options.count

        // THE SELECTION IS NOT YELLOW YET, and it is worth writing down why so the
        // next person does not spend the afternoon I did on it.
        //
        // `selectedSegmentBezelColor` is the documented API and AppKit ignores it here.
        // Three approaches were tried and photographed: the property alone, the
        // property with `segmentStyle = .roundRect`, and an `NSSegmentedCell` subclass
        // overriding `drawSegment`. All three rendered the same system grey, because a
        // modern NSSegmentedControl no longer draws through its cell.
        //
        // The selection is currently said with the caret (▸A) and with BOTH lighting
        // every segment, which is legible but is not the app's colour language, where
        // yellow means SELECTED and red means LIVE.
        //
        // The fix is to replace this control with two of the app's own VBOptionButton
        // keys, which colour reliably because they draw themselves — that is how CUT,
        // FADE, BEAT and the bus keys all light. It is deferred rather than difficult:
        // UISelfQA's section 11 finds this selector AS an NSSegmentedControl, asserts
        // it has two segments, and clicks it by setting `selectedSegment` and firing
        // target/action, so the swap means rewriting that check too.

        // BOTH genuinely LIGHTS BOTH. `.selectAny` is what makes that possible: the
        // default one-of-N tracking can only ever bezel a single segment, so BOTH used
        // to show the last channel highlighted with a caret on every label — which
        // reads as "B, and something odd is going on" rather than as "both". The
        // selector covering its whole width is the state, and it is the one a glance
        // has to be able to tell apart from "B".
        //
        // Tracking mode does not decide behaviour here; `cardChannelChanged` advances
        // the state itself and this function then paints it. The mode only controls
        // what the control is ALLOWED to show.
        control.trackingMode = .selectAny
        for index in options.indices {
            control.setSelected(isBoth || index == state, forSegment: index)
        }
        for (index, name) in options.enumerated() {
            let isLit = isBoth || index == state
            control.setLabel(isLit ? Theme.focusCaret + name : name, forSegment: index)
        }
    }

    @objc private func cardChannelChanged(_ sender: NSSegmentedControl) {
        guard let name = sender.identifier?.rawValue,
              let options = effects.first(where: { $0.name == name })?.channelOptions
        else { return }

        // ONE GESTURE, THREE STATES, ALWAYS IN THE SAME ORDER.
        //
        //     A  ->  B  ->  BOTH  ->  A
        //
        // A click ADVANCES, wherever on the control it lands. It used to be a picker:
        // clicking a segment selected that segment, and BOTH was reached only by
        // clicking the last segment when it was already selected. That makes the same
        // click mean different things depending on the state you were already in — you
        // had to know where you were before you knew what a click would do, which is
        // not something anyone can hold onto mid-set.
        //
        // Advancing means the control is aimed at rather than read: hit it once to get
        // to B, again to cover both. The cost is that going from BOTH back to a
        // specific channel can take two clicks instead of one. That is the right trade
        // for a control you operate without looking.
        let previous = cardChannelSelection[name] ?? 0
        let next = (previous + 1) % (options.count + 1)

        cardChannelSelection[name] = next
        restyleFocus(sender, options: options, state: next)
        onCardChannelChanged?(name, next)
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
                label.stringValue = valueTexts[effectName]?[code]?.text(for: value) ?? String(format: "%.2f", value)
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

    /// Replaces the cards, keeping each card's fold and channel choice by name.
    /// For when the chain itself changed — an effect added or removed.
    func setEffects(_ newEffects: [EffectCardModel]) {
        effects = newEffects
        for effect in newEffects { cardChannelSelection[effect.name] = effect.initialChannelIndex }
        let names = Set(newEffects.map(\.name))
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
