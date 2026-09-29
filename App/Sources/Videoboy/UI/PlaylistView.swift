//
//  PlaylistView.swift — one source's up-next queue, as a list.
//
//  Purpose : The view behind a library's A / B (or C / D) tab. Shows what is queued
//            for that source, in play order, with the next one marked — because the
//            only question this view exists to answer quickly is "what comes next".
//            A REPEAT key heads the list: lit (the default), a played clip goes to
//            the bottom so the queue cycles; dark, it leaves the queue.
//  Inputs  : `setItems` and `setRepeats`, whenever that channel's playlist changes.
//  Outputs : `onRemove`, when a row's ✕ is pressed; `onRepeatChanged`, on REPEAT.
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

    /// Called when REPEAT is toggled, with its new state.
    var onRepeatChanged: ((Bool) -> Void)?

    private let channel: String
    private let stack = NSStackView()
    private let emptyLabel: NSTextField

    /// REPEAT: lit = played clips go to the bottom; dark = they leave the queue.
    private let repeatKey = VBOptionButton(title: "REPEAT")
    /// Says in words what REPEAT is doing, beside it.
    private let repeatCaption = Controls.label(
        "", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

    /// The number and name labels of each row, parallel to `stack.arrangedSubviews`,
    /// so a take can restyle rows in place instead of rebuilding them.
    private var rowLabels: [(number: NSTextField, name: NSTextField)] = []

    init(channel: String) {
        self.channel = channel
        self.emptyLabel = Controls.label(
            "Nothing queued for \(channel). Right-click a clip to add it, "
                + "then set the source to 1 so it plays the queue.",
            font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        super.init(frame: .zero)

        // REPEAT heads the list, where the eye already is when checking the queue.
        repeatKey.isOn = true
        repeatKey.target = self
        repeatKey.action = #selector(repeatToggled)
        repeatKey.toolTip = "REPEAT on: a clip that plays goes to the bottom of \(channel)'s queue, "
            + "so the queue never runs out. Off: it leaves the queue."
        repeatKey.setContentCompressionResistancePriority(.required, for: .horizontal)
        repeatCaption.lineBreakMode = .byTruncatingTail
        repeatCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = Controls.row([repeatKey, repeatCaption, Controls.spacer()], spacing: 6)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        showRepeatState()

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
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }

    /// Points REPEAT at the queue's state without firing its action.
    func setRepeats(_ repeats: Bool) {
        guard repeatKey.isOn != repeats else { return }
        repeatKey.isOn = repeats
        showRepeatState()
    }

    /// REPEAT's state — for self-QA.
    var repeatsForChecks: Bool { repeatKey.isOn }

    /// Presses REPEAT the way a click does — for self-QA.
    func toggleRepeatForChecks() {
        repeatKey.isOn.toggle()
        repeatToggled()
    }

    @objc private func repeatToggled() {
        showRepeatState()
        onRepeatChanged?(repeatKey.isOn)
    }

    private func showRepeatState() {
        repeatCaption.stringValue = repeatKey.isOn ? "played clips go to the bottom" : "played clips leave the queue"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// What is shown, so the common change can be done without a rebuild.
    private var shownItems: [PlaylistItem] = []

    /// Replaces the list, touching as few rows as it can: a queue can hold up to the
    /// Up Next limit (hundreds of rows), and this runs on the main thread mid-show.
    /// In place: unchanged (nothing), one row removed (a take with REPEAT off, or a
    /// ✕), top row to the bottom (a take with REPEAT on), clips added at the end.
    /// Only anything else — Play Next, a clear — rebuilds the whole list.
    func setItems(_ items: [PlaylistItem]) {
        defer { shownItems = items }
        let inPlace = stack.arrangedSubviews.count == shownItems.count
            && rowLabels.count == shownItems.count
        // Every queue edit refreshes all four lists; the unchanged ones stop here.
        if inPlace, items == shownItems { return }
        if inPlace, !shownItems.isEmpty, items.count == shownItems.count - 1,
           case let gone = items.indices.first(where: { items[$0].id != shownItems[$0].id }) ?? items.count,
           items == Array(shownItems[..<gone]) + Array(shownItems[(gone + 1)...]) {
            let row = stack.arrangedSubviews[gone]
            stack.removeArrangedSubview(row)
            row.discardFromSuperview()
            rowLabels.remove(at: gone)
            restyleRows()
            emptyLabel.isHidden = !items.isEmpty
            return
        }
        if inPlace, items.count > 1, items.count == shownItems.count,
           items == Array(shownItems.dropFirst()) + [shownItems[0]] {
            let top = stack.arrangedSubviews[0]
            stack.removeArrangedSubview(top)
            stack.addArrangedSubview(top)
            rowLabels.append(rowLabels.removeFirst())
            restyleRows()
            return
        }
        if inPlace, items.count > shownItems.count, Array(items.prefix(shownItems.count)) == shownItems {
            for item in items.dropFirst(shownItems.count) {
                stack.addArrangedSubview(row(for: item))
            }
            restyleRows()
            emptyLabel.isHidden = true
            return
        }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.discardFromSuperview()
        }
        rowLabels = []

        emptyLabel.isHidden = !items.isEmpty

        for item in items {
            stack.addArrangedSubview(row(for: item))
        }
        restyleRows()
    }

    private func row(for item: PlaylistItem) -> NSView {
        // Sized for three digits, then numbered by `restyleRows`: a take renumbers
        // rows in place, so every row's number column has to be the same width.
        let number = Controls.monoLabel("000", color: Theme.Color.textTertiary, holdsWidth: true)
        number.alignment = .right

        let name = Controls.label(item.displayName, color: Theme.Color.textSecondary)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = item.url.path
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let remove = Controls.button("✕", target: self, action: #selector(removePressed(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        remove.toolTip = "Take \(item.displayName) out of \(channel)'s queue"

        rowLabels.append((number, name))
        return Controls.row([number, name, Controls.spacer(), remove], spacing: 4)
    }

    /// Numbers the rows in play order. The first row is what plays next, so it is
    /// the one that gets the accent; everything below it is just order.
    private func restyleRows() {
        for (position, labels) in rowLabels.enumerated() {
            let isNext = position == 0
            let text = isNext ? "▸" : "\(position + 1)"
            if labels.number.stringValue != text { labels.number.stringValue = text }
            // Set only on change: every set invalidates the label, and this walks
            // every row on every take.
            let numberColor = isNext ? Theme.Color.accent : Theme.Color.textTertiary
            let nameColor = isNext ? Theme.Color.textPrimary : Theme.Color.textSecondary
            if labels.number.textColor != numberColor { labels.number.textColor = numberColor }
            if labels.name.textColor != nameColor { labels.name.textColor = nameColor }
        }
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onRemove?(id)
    }
}
