//
//  RoutingPopover.swift — the list behind the send glyph under each preview.
//
//  Purpose : macOS asks "where do you want this?" with one glyph and a short list,
//            and everyone already knows how to use it. This is that list: every
//            display, then every destination defined in preferences, with the ones
//            that cannot be served yet greyed and saying why.
//  Inputs  : the source being routed and the router that knows what exists.
//  Outputs : a route chosen, or one cleared.
//  Connects: OutputRouter, MetalPreviewView (which carries the glyph).
//  Extend  : nothing here decides what CAN be routed — that is the router's job, and
//            keeping the decision there is what stops this list and the actual
//            capability drifting apart.
//

import AppKit
import VideoboyCore

/// The destination list for one source.
final class RoutingPopover: NSViewController {

    private let source: RoutingSource
    private let router: OutputRouter
    private let onChosen: (RoutingDestination?) -> Void

    init(
        source: RoutingSource, router: OutputRouter,
        onChosen: @escaping (RoutingDestination?) -> Void
    ) {
        self.source = source
        self.router = router
        self.onChosen = onChosen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func loadView() {
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [
            Controls.label("Send \(source.displayName) to",
                           font: Theme.Font.panelTitle, color: Theme.Color.textPrimary)
        ]

        let active = Set(router.destinations(showing: source))
        let options = router.availableOptions()

        if options.isEmpty {
            rows.append(Controls.note(
                "No displays other than this one, and nothing defined in Settings › Outputs.",
                width: 250))
        }

        for option in options {
            let isActive = active.contains(option.destination)
            let button = NSButton(
                title: "\(isActive ? "✓  " : "    ")\(option.name)",
                target: self, action: #selector(optionChosen(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.font = Theme.Font.label
            button.isEnabled = option.isAvailable
            button.contentTintColor = isActive ? Theme.Color.accent : Theme.Color.textSecondary
            button.tag = options.firstIndex { $0.destination == option.destination } ?? 0

            rows.append(button)
            rows.append(Controls.note(
                option.unavailableReason ?? option.detail, width: 250))
        }

        if !active.isEmpty {
            rows.append(Controls.button(
                "Stop sending", target: self, action: #selector(stopSending)))
        }

        self.options = options

        let column = Controls.column(rows, spacing: 4)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: 286)
        ])
        view = content
    }

    private var options: [RoutingOption] = []

    @objc private func optionChosen(_ sender: NSButton) {
        guard options.indices.contains(sender.tag) else { return }
        onChosen(options[sender.tag].destination)
    }

    @objc private func stopSending() {
        onChosen(nil)
    }
}
