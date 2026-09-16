//
//  Controls.swift — factories for the standard AppKit controls, styled once.
//
//  Purpose : SPEC 14.3 requires real AppKit controls, not hand-rolled replacements,
//            and every one of them styled consistently. These factories are how that
//            stays true without each panel repeating the same six lines.
//  Inputs  : titles, items, ranges.
//  Outputs : configured NSPopUpButton / NSSegmentedControl / NSSwitch / NSSlider /
//            NSSearchField / labels.
//  Connects: every panel body in UI/.
//  Extend  : add a factory when a third panel needs the same control twice. Do not
//            add styling at a call site — change it here so all of them move together.
//

import AppKit
import VideoboyCore

/// Builders for the app's controls. All of them return real AppKit views.
enum Controls {

    /// A label. `secondary` and `tertiary` follow the mockup's text tiers.
    static func label(
        _ text: String, font: NSFont = Theme.Font.label, color: NSColor = Theme.Color.textSecondary
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// A monospaced readout: param codes, negotiated modes, fps counters.
    static func monoLabel(_ text: String, color: NSColor = Theme.Color.textSecondary) -> NSTextField {
        label(text, font: Theme.Font.mono, color: color)
    }

    /// A push button. `enabled: false` is how an unbuilt feature is shown — present
    /// and visibly inert, never omitted (CLAUDE.md).
    static func button(_ title: String, enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.Font.label
        button.isEnabled = enabled
        return button
    }

    /// A selector popup. Every selector in the app is one of these (SPEC 14.3).
    static func popUp(_ items: [String], enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: items)
        popUp.controlSize = .small
        popUp.font = Theme.Font.label
        popUp.isEnabled = enabled
        popUp.target = target
        popUp.action = action
        return popUp
    }

    /// A segmented control for tab strips and mutually exclusive toggles.
    static func segmented(_ labels: [String], selected: Int = 0, enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: target, action: action)
        control.controlSize = .small
        control.font = Theme.Font.tinyLabel
        control.selectedSegment = selected
        control.isEnabled = enabled
        return control
    }

    /// A boolean switch, used for effect enables and the settings-bar toggles.
    static func toggle(on: Bool = false, enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil) -> NSSwitch {
        let control = NSSwitch()
        control.state = on ? .on : .off
        control.isEnabled = enabled
        control.controlSize = .mini
        control.target = target
        control.action = action
        return control
    }

    /// A continuous slider for any parameter or crossfader.
    static func slider(
        value: Double = 0.5, minimum: Double = 0, maximum: Double = 1,
        enabled: Bool = true, target: AnyObject? = nil, action: Selector? = nil
    ) -> NSSlider {
        let slider = NSSlider(value: value, minValue: minimum, maxValue: maximum, target: target, action: action)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.isEnabled = enabled
        return slider
    }

    /// A search field for the libraries and the asset browser.
    static func searchField(placeholder: String, enabled: Bool = true) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = Theme.Font.label
        field.isEnabled = enabled
        return field
    }

    /// A horizontal row of views with consistent spacing.
    static func row(_ views: [NSView], spacing: CGFloat = Theme.Metrics.controlSpacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// A vertical column of views with consistent spacing.
    static func column(_ views: [NSView], spacing: CGFloat = Theme.Metrics.controlSpacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// A flexible spacer that pushes what follows it to the trailing edge.
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    /// The mapping badges beside a parameter: M(IDI), S(audio-react), C(lock-LFO).
    /// Shown for every mappable parameter so the param code and its bindings are
    /// legible at a glance (SPEC 14.2).
    ///
    /// Non-interactive version, for rows whose feature is not built yet.
    static func mappingBadges(_ letters: [String], active: Set<String> = []) -> NSStackView {
        let badges = letters.map { letter -> NSTextField in
            let badge = label(letter, font: Theme.Font.tinyLabel,
                              color: active.contains(letter) ? Theme.Color.accent : Theme.Color.textTertiary)
            badge.alignment = .center
            return badge
        }
        return row(badges, spacing: 2)
    }

    /// A clickable mapping badge.
    ///
    /// These are small on purpose — the mockup's geometry is tight — so they are
    /// buttons with no bezel rather than styled labels, which keeps the hit target
    /// and the keyboard behaviour that AppKit already gets right.
    static func mappingBadgeButton(
        _ letter: String, isActive: Bool, target: AnyObject?, action: Selector?
    ) -> NSButton {
        let button = NSButton(title: letter, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = Theme.Font.tinyLabel
        button.contentTintColor = isActive ? Theme.Color.accent : Theme.Color.textTertiary
        button.setButtonType(.momentaryChange)
        // Room for one character plus a little slack, so the row stays tight.
        button.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return button
    }
}
