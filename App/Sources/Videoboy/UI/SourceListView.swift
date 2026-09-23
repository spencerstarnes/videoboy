//
//  SourceListView.swift — the + / − list of configured sources.
//
//  Purpose : Settings > Sources' editor. Shape copied deliberately from
//            `DestinationListView` (the Outputs pane's list) — a list on the left, an
//            editor for the selected entry on the right, +/- beneath. People already
//            know how to drive this because every macOS settings window uses it.
//  Inputs  : a PreferenceStore, whose `configuredSources` this reads and writes; the
//            Engine, read-only, for whether a source's node has actually delivered a
//            frame (the live/greyed state a plain preference can't tell you).
//  Outputs : edits, saved through the store immediately, same as every other pane.
//  Connects: PreferencePanes (Inputs/Sources), `ConfiguredSource`,
//            `LiveAVFoundationCapture.discoverDevices`, `WindowCaptureSession`.
//  Extend  : a new source kind is a case on `ConfiguredSourceKind` plus a branch in
//            `addSource`'s menu and in `updateEditor` for however its target reads.
//
//  ── WHY + OPENS A MENU RATHER THAN APPENDING A BLANK ROW ────────────────────────
//
//  `DestinationListView.addDestination()` can append "New destination" and let the
//  editor fill in — every destination kind's target is just typed text. A source is
//  not: "only the AVFoundation stuff that macOS natively sees should be auto-
//  populated" was the explicit ask, so a camera has to be PICKED from a real
//  enumeration, not typed, and a window has to be picked from what is actually on
//  screen right now. A blank row with a kind popup would let someone type a camera
//  name that does not exist and never find out why it never connects.
//

import AppKit
import VideoboyCore

/// A list of configured sources with an editor for the selected one.
final class SourceListView: NSView {

    private let store: PreferenceStore
    private unowned let engine: Engine
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let editor = FlippedView()
    private let emptyState = Controls.label(
        "Press + to add a camera, a captured window, an IP camera or a DV deck.",
        color: Theme.Color.textTertiary)
    private var selectedIndex: Int?

    private let nameField = NSTextField(string: "")
    private let kindLabel = Controls.label("", color: Theme.Color.textSecondary)
    private let statusLabel = Controls.label("", color: Theme.Color.textTertiary)
    private let targetField = NSTextField(string: "")

    init(store: PreferenceStore, engine: Engine) {
        self.store = store
        self.engine = engine
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

        let add = Controls.button("+", target: self, action: #selector(presentAddMenu(_:)))
        let remove = Controls.button("−", target: self, action: #selector(removeSource))
        let buttons = Controls.row([add, remove, Controls.spacer()], spacing: 4)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        nameField.target = self
        nameField.action = #selector(fieldEdited)
        targetField.target = self
        targetField.action = #selector(fieldEdited)
        for field in [nameField, targetField] {
            field.font = Theme.Font.label
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        let form = Controls.column([
            labelled("Name", nameField),
            labelled("Kind", kindLabel),
            labelled("Target", targetField),
            statusLabel
        ], spacing: 8)
        form.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(form)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.lineBreakMode = .byWordWrapping
        emptyState.maximumNumberOfLines = 3

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
            emptyState.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: editor.trailingAnchor)
        ])
    }

    private func labelled(_ caption: String, _ control: NSView) -> NSView {
        let label = Controls.label(caption, color: Theme.Color.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return Controls.row([label, control, Controls.spacer()], spacing: 8)
    }

    // MARK: - Adding

    @objc private func presentAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // "Only the AVFoundation stuff that macOS natively sees should be
        // auto-populated" — so Camera is a SUBMENU of the real enumeration, picked,
        // never typed.
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        let cameraNames = LiveAVFoundationCapture.discoverDevices().map(\.localizedName)
        if cameraNames.isEmpty {
            cameraItem.isEnabled = false
            cameraItem.title = "Camera (none found)"
        } else {
            let submenu = NSMenu()
            for name in cameraNames {
                let item = NSMenuItem(
                    title: name, action: #selector(addCamera(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                submenu.addItem(item)
            }
            cameraItem.submenu = submenu
        }
        menu.addItem(cameraItem)

        let windowItem = NSMenuItem(
            title: "Window Capture…", action: #selector(presentWindowPicker), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)

        let ipItem = NSMenuItem(
            title: "IP Camera…", action: #selector(addIPCamera), keyEquivalent: "")
        ipItem.target = self
        menu.addItem(ipItem)

        let dvItem = NSMenuItem(
            title: "DV Deck…", action: #selector(addDVDeck), keyEquivalent: "")
        dvItem.target = self
        menu.addItem(dvItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func addCamera(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        append(ConfiguredSource(kind: .avfoundation, name: name, target: name))
    }

    @objc private func presentWindowPicker() {
        Task { @MainActor in
            let windows: [WindowCandidate]
            do {
                windows = try await WindowCaptureSession.availableWindows()
            } catch {
                Log.warn(.app, "could not list windows to capture: \(error)")
                return
            }
            guard !windows.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No windows found"
                alert.informativeText = "Nothing capturable is on screen right now."
                alert.runModal()
                return
            }
            let menu = NSMenu()
            for window in windows {
                let item = NSMenuItem(
                    title: window.displayName, action: #selector(self.addWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = window
                menu.addItem(item)
            }
            // Positioned at the list, not the (now long-gone) menu-click point — this
            // arrives asynchronously, after `SCShareableContent` answers.
            menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: self.scrollView)
        }
    }

    @objc private func addWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowCandidate else { return }
        append(ConfiguredSource(
            kind: .windowCapture,
            name: window.title.isEmpty ? window.ownerName : window.title,
            target: window.title, windowOwnerName: window.ownerName))
    }

    @objc private func addIPCamera() {
        let alert = NSAlert()
        alert.messageText = "Add IP Camera"
        alert.informativeText = "Saved now; live decode is not built yet (SPEC §6/§15) — "
            + "this entry shows greyed in Sources until it is."
        let name = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        name.placeholderString = "Name"
        let url = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        url.placeholderString = "rtsp://…"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        accessory.addSubview(name)
        accessory.addSubview(url)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let named = name.stringValue.isEmpty ? "IP Camera" : name.stringValue
        append(ConfiguredSource(kind: .ipCamera, name: named, target: url.stringValue))
    }

    @objc private func addDVDeck() {
        let alert = NSAlert()
        alert.messageText = "Add DV Deck"
        alert.informativeText = "Saved now; live FireWire/IIDC capture is not built — "
            + "this entry shows greyed in Sources until it is (docs/BUILD-PLAN.md)."
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = "Name"
        alert.accessoryView = name
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let named = name.stringValue.isEmpty ? "DV Deck" : name.stringValue
        append(ConfiguredSource(kind: .dvDeck, name: named))
    }

    private func append(_ source: ConfiguredSource) {
        store.preferences.configuredSources.append(source)
        reload()
        let index = store.preferences.configuredSources.count - 1
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        Log.info(.app, "added source '\(source.name)' (\(source.kind.displayName))")
    }

    // MARK: - Editing

    @objc private func removeSource() {
        guard let index = selectedIndex,
              store.preferences.configuredSources.indices.contains(index) else { return }
        let removed = store.preferences.configuredSources.remove(at: index)
        selectedIndex = nil
        reload()
        Log.info(.app, "removed source '\(removed.name)'")
    }

    @objc private func fieldEdited() {
        guard let index = selectedIndex,
              store.preferences.configuredSources.indices.contains(index) else { return }
        var source = store.preferences.configuredSources[index]
        source.name = nameField.stringValue
        // Target is editable only for the kinds where it is free text the person
        // typed (.ipCamera's URL, .dvDeck's note) — .avfoundation and .windowCapture
        // were PICKED from a real enumeration and retyping them would just break the
        // match, so their target field stays disabled (see `updateEditor`).
        if source.kind == .ipCamera || source.kind == .dvDeck {
            source.target = targetField.stringValue
        }
        store.preferences.configuredSources[index] = source
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    private func reload() {
        tableView.reloadData()
        if selectedIndex == nil && !store.preferences.configuredSources.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateEditor()
    }

    private func updateEditor() {
        guard let index = selectedIndex,
              store.preferences.configuredSources.indices.contains(index) else {
            editor.isHidden = true
            emptyState.isHidden = false
            return
        }
        editor.isHidden = false
        emptyState.isHidden = true
        let source = store.preferences.configuredSources[index]
        nameField.stringValue = source.name
        kindLabel.stringValue = source.kind.displayName
        targetField.stringValue = source.target
        targetField.isEnabled = source.kind == .ipCamera || source.kind == .dvDeck

        if let reason = source.kind.unimplementedReason {
            statusLabel.stringValue = reason
            statusLabel.textColor = Theme.Color.textTertiary
        } else if engine.captureNodes[source.id]?.isLive == true {
            statusLabel.stringValue = "Live"
            statusLabel.textColor = Theme.Color.accent
        } else {
            statusLabel.stringValue = "Configured — not currently receiving frames"
            statusLabel.textColor = Theme.Color.textTertiary
        }
    }
}

extension SourceListView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.preferences.configuredSources.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard store.preferences.configuredSources.indices.contains(row) else { return nil }
        let source = store.preferences.configuredSources[row]
        return Controls.label(
            "\(source.name)  ·  \(source.kind.displayName)", color: Theme.Color.textSecondary)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        updateEditor()
    }
}
