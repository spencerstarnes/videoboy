//
//  DestinationListView.swift — the + / − list of output destinations.
//
//  Purpose : The Outputs pane's editor: a list of destinations on the left, the
//            settings for the selected one on the right, and + / − beneath. The
//            shape macOS uses everywhere for "a list of things you define", because
//            people already know how to drive it.
//  Inputs  : a PreferenceStore, whose `destinations` this reads and writes.
//  Outputs : edits, saved through the store immediately.
//  Connects: PreferencePanes (Outputs), and later the routing popovers, which offer
//            these alongside the displays found at runtime.
//  Extend  : a new destination kind is a case on `OutputDestination.Kind` plus
//            whatever its target field should be called here.
//

import AppKit
import VideoboyCore

/// A list of output destinations with an editor for the selected one.
final class DestinationListView: NSView {

    private let store: PreferenceStore
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let editor = FlippedView()
    private let emptyState = Controls.label(
        "Select a destination, or press + to add one.",
        color: Theme.Color.textTertiary)
    private var selectedIndex: Int?

    private let nameField = NSTextField(string: "")
    private let targetField = NSTextField(string: "")
    private let kindPopUp = Controls.popUp(OutputDestination.Kind.allCases.map(\.displayName))

    init(store: PreferenceStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private func build() {
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.backgroundColor = Theme.Color.panelFillNested
        tableView.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 200
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .lineBorder

        let add = Controls.button("+", target: self, action: #selector(addDestination))
        let remove = Controls.button("−", target: self, action: #selector(removeDestination))
        let buttons = Controls.row([add, remove, Controls.spacer()], spacing: 4)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // The editor for whatever is selected.
        nameField.target = self
        nameField.action = #selector(fieldEdited)
        targetField.target = self
        targetField.action = #selector(fieldEdited)
        kindPopUp.target = self
        kindPopUp.action = #selector(fieldEdited)
        for field in [nameField, targetField] {
            field.font = Theme.Font.label
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        let form = Controls.column([
            labelled("Name", nameField),
            labelled("Kind", kindPopUp),
            labelled("Target", targetField),
            Controls.note(
                "Target is what the kind needs: a host:port for OBS or an IP stream, "
                + "a window title, a device name, or a bus for a feedback send.",
                width: 340)
        ], spacing: 8)
        form.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(form)

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(buttons)
        addSubview(editor)
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: 190),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),

            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 190),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),

            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),

            form.topAnchor.constraint(equalTo: editor.topAnchor),
            form.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: editor.trailingAnchor),

            emptyState.topAnchor.constraint(equalTo: editor.topAnchor, constant: 4),
            emptyState.leadingAnchor.constraint(equalTo: editor.leadingAnchor)
        ])
    }

    private func labelled(_ caption: String, _ control: NSView) -> NSView {
        let label = Controls.label(caption, color: Theme.Color.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        // A minimum, not a fixed width: a fixed one made the Outputs pane demand a
        // wider window than the others and the window resized as you changed tabs,
        // which reads as a glitch rather than as a layout.
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return Controls.row([label, control, Controls.spacer()], spacing: 8)
    }

    // MARK: - Editing

    @objc private func addDestination() {
        // Starts as OBS because it is the destination most people add first and the
        // only one whose transport already exists.
        let destination = OutputDestination(
            kind: .obs, name: "New destination", target: "127.0.0.1:9000")
        store.preferences.destinations.append(destination)
        reload()
        let index = store.preferences.destinations.count - 1
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        Log.info(.app, "added output destination '\(destination.name)'")
    }

    @objc private func removeDestination() {
        guard let index = selectedIndex,
              store.preferences.destinations.indices.contains(index) else { return }
        let removed = store.preferences.destinations.remove(at: index)
        selectedIndex = nil
        reload()
        Log.info(.app, "removed output destination '\(removed.name)'")
    }

    @objc private func fieldEdited() {
        guard let index = selectedIndex,
              store.preferences.destinations.indices.contains(index) else { return }
        var destination = store.preferences.destinations[index]
        destination.name = nameField.stringValue
        destination.target = targetField.stringValue
        let kinds = OutputDestination.Kind.allCases
        if kinds.indices.contains(kindPopUp.indexOfSelectedItem) {
            destination.kind = kinds[kindPopUp.indexOfSelectedItem]
        }
        store.preferences.destinations[index] = destination
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integer: 0))
    }

    private func reload() {
        tableView.reloadData()
        // Select something if there is something to select. A list with rows in it
        // and a blank editor beside them looks broken, and the first row is as good
        // a guess as any at what someone opening this pane came to look at.
        if selectedIndex == nil && !store.preferences.destinations.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateEditor()
    }

    /// Shows the selected destination, or nothing when there is no selection.
    private func updateEditor() {
        guard let index = selectedIndex,
              store.preferences.destinations.indices.contains(index) else {
            editor.isHidden = true
            emptyState.isHidden = false
            return
        }
        editor.isHidden = false
        emptyState.isHidden = true
        let destination = store.preferences.destinations[index]
        nameField.stringValue = destination.name
        targetField.stringValue = destination.target
        kindPopUp.selectItem(at:
            OutputDestination.Kind.allCases.firstIndex(of: destination.kind) ?? 0)
    }
}

extension DestinationListView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.preferences.destinations.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard store.preferences.destinations.indices.contains(row) else { return nil }
        let destination = store.preferences.destinations[row]
        let label = Controls.label(
            "\(destination.name)  ·  \(destination.kind.displayName)",
            color: Theme.Color.textSecondary)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        updateEditor()
    }
}
