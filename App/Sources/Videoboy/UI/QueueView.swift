//
//  PlaylistView.swift — one source's up-next queue, as a list.
//
//  Purpose : The view behind a library's A / B (or C / D) tab. Shows what is queued
//            for that source, in play order, with the next one marked — because the
//            only question this view exists to answer quickly is "what comes next".
//  Inputs  : `setItems`, called whenever that channel's playlist changes.
//  Outputs : `onRemove`, when a row's ✕ is pressed.
//  Connects: LibraryPanelBody (which owns one per channel), ShellController (which
//            owns the playlists themselves).
//  Extend  : drag-to-reorder belongs here, driven onto `Playlist.move` — do not add
//            a second ordering mechanism.
//

import AppKit
import VideoboyCore

/// A simple ordered list of queued clips for one channel.
final class PlaylistView: NSView {

    /// Called with the item to drop from the queue.
    var onRemove: ((PlaylistItem.ID) -> Void)?

    private let channel: String
    private let stack = NSStackView()
    private let emptyLabel: NSTextField

    init(channel: String) {
        self.channel = channel
        self.emptyLabel = Controls.label(
            "Nothing queued for \(channel). Right-click a clip to add it, "
                + "then set the source to 1 so it plays the queue.",
            font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// What is shown, so the common change can be done without a rebuild.
    private var shownItems: [PlaylistItem] = []

    /// Replaces the list. The one change that happens at a TAKE — ADV taking the top
    /// clip — only removes the top row and restyles the new top one (the accent
    /// moves); anything else rebuilds, since a queue is a handful of rows.
    func setItems(_ items: [PlaylistItem]) {
        defer { shownItems = items }
        if !shownItems.isEmpty, items == Array(shownItems.dropFirst()),
           stack.arrangedSubviews.count == shownItems.count {
            let top = stack.arrangedSubviews[0]
            stack.removeArrangedSubview(top)
            top.discardFromSuperview()
            if let first = items.first, let old = stack.arrangedSubviews.first {
                stack.removeArrangedSubview(old)
                old.discardFromSuperview()
                stack.insertArrangedSubview(row(for: first, position: 0), at: 0)
            }
            emptyLabel.isHidden = !items.isEmpty
            return
        }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.discardFromSuperview()
        }

        emptyLabel.isHidden = !items.isEmpty

        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(row(for: item, position: index))
        }
    }

    private func row(for item: PlaylistItem, position: Int) -> NSView {
        // The first row is what plays next, so it is the one that gets the accent.
        // Everything below it is just order.
        let isNext = position == 0
        let number = Controls.monoLabel(
            isNext ? "▸" : "\(position + 1)",
            color: isNext ? Theme.Color.accent : Theme.Color.textTertiary,
            holdsWidth: true)

        let name = Controls.label(
            item.displayName,
            color: isNext ? Theme.Color.textPrimary : Theme.Color.textSecondary)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = item.url.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let remove = Controls.button("✕", target: self, action: #selector(removePressed(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        remove.toolTip = "Take \(item.displayName) out of \(channel)'s queue"

        return Controls.row([number, name, Controls.spacer(), remove], spacing: 4)
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onRemove?(id)
    }
}
