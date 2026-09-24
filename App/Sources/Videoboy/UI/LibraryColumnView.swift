//
//  LibraryColumnView.swift — the library as the Finder's columns.
//
//  Purpose : The left column is the top level — bins first, marked with a chevron,
//            then loose clips. Select a bin and its clips fill the right column.
//            Every column selects, drags, drops and right-clicks like a list: drop on
//            a bin row to file clips there, on the right column to file them in the
//            open bin. ← and → move between columns, as they do in the Finder.
//  Inputs   : a LibraryBrowser; its `openBin` is the right column.
//  Outputs  : LibraryBrowserActions calls, the same as the other two views.
//  Connects : LibraryPanelBody, LibraryBrowser, LibraryListView (shares its cells).
//  Extend   : bins are one level deep, so two columns are the whole chain. If bins
//             ever nest, this becomes an array of columns — not a second view.
//
//  ── WHY THIS REPLACED THE BIN BUTTONS ───────────────────────────────────────────
//
//  "Column view" used to be a strip of buttons beside the icon grid, one per bin plus
//  ALL. ALL was the default and showed exactly what icon view showed, the buttons took
//  no drops and had no menu, and so nothing about it behaved like a column — or like
//  a folder.
//

import AppKit

/// The column view.
final class LibraryColumnView: NSView {

    let browser: LibraryBrowser
    weak var actions: LibraryBrowserActions?

    let rootTable = LibraryColumnTable()
    let binTable = LibraryColumnTable()
    private let binColumn = NSView()
    private let hint = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

    private(set) var rootEntries: [LibraryEntry] = []
    private(set) var binEntries: [LibraryEntry] = []

    private var isApplyingSelection = false

    init(browser: LibraryBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rootScroll = Self.configure(rootTable, owner: self)
        let binScroll = Self.configure(binTable, owner: self)

        binColumn.translatesAutoresizingMaskIntoConstraints = false
        binColumn.addSubview(binScroll)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.alignment = .center
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        binColumn.addSubview(hint)

        // Laid out with plain constraints, not a stack view. A horizontal stack with a
        // zero-sized separator box resolved ambiguously: in the asset browser both
        // columns ended up squashed against the bottom edge with the "divider" drawn
        // as a horizontal line across them.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.Color.separator.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [rootScroll, divider, binColumn] { addSubview(view) }
        self.divider = divider

        // Always: both columns and the divider run top to bottom, the left column
        // starts at the left edge, and the right column's contents fill it.
        NSLayoutConstraint.activate([
            rootScroll.topAnchor.constraint(equalTo: topAnchor),
            rootScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: Theme.Metrics.hairline),
            binColumn.topAnchor.constraint(equalTo: topAnchor),
            binColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            binScroll.topAnchor.constraint(equalTo: binColumn.topAnchor),
            binScroll.leadingAnchor.constraint(equalTo: binColumn.leadingAnchor),
            binScroll.trailingAnchor.constraint(equalTo: binColumn.trailingAnchor),
            binScroll.bottomAnchor.constraint(equalTo: binColumn.bottomAnchor),
            hint.centerYAnchor.constraint(equalTo: binColumn.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: binColumn.leadingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: binColumn.trailingAnchor, constant: -8)
        ])
        // Two columns: equal halves either side of the divider.
        twoColumnConstraints = [
            divider.leadingAnchor.constraint(equalTo: rootScroll.trailingAnchor),
            binColumn.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            binColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            binColumn.widthAnchor.constraint(equalTo: rootScroll.widthAnchor)
        ]
        // One column (searching, or a tab with no bins): the left one takes the width.
        oneColumnConstraints = [
            rootScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.leadingAnchor.constraint(equalTo: trailingAnchor),
            binColumn.leadingAnchor.constraint(equalTo: trailingAnchor),
            binColumn.widthAnchor.constraint(equalToConstant: 0)
        ]
        NSLayoutConstraint.activate(twoColumnConstraints)
    }

    private var twoColumnConstraints: [NSLayoutConstraint] = []
    private var oneColumnConstraints: [NSLayoutConstraint] = []

    private var divider: NSView?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private static func configure(_ table: LibraryColumnTable, owner: LibraryColumnView) -> NSScrollView {
        table.columnView = owner
        table.style = .plain
        table.rowHeight = 18
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = owner
        table.delegate = owner
        table.target = owner
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.setDraggingSourceOperationMask(LibraryDragSource.operationMask(for: .outsideApplication), forLocal: false)
        table.setDraggingSourceOperationMask(LibraryDragSource.operationMask(for: .withinApplication), forLocal: true)
        table.registerForDraggedTypes(LibraryBrowser.droppedTypes)
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - Contents

    func reload() {
        rootEntries = browser.rootEntries()
        let open = browser.effectiveOpenBin
        binEntries = open.map { browser.entries(inBin: $0) } ?? []

        // Searching, or a tab with no bins: one column says it all.
        let twoColumns = browser.showsBins
        binColumn.isHidden = !twoColumns
        divider?.isHidden = !twoColumns
        // Swap which constraint sizes the left column, so a hidden right column does
        // not leave half the view empty.
        if twoColumns {
            NSLayoutConstraint.deactivate(oneColumnConstraints)
            NSLayoutConstraint.activate(twoColumnConstraints)
        } else {
            NSLayoutConstraint.deactivate(twoColumnConstraints)
            NSLayoutConstraint.activate(oneColumnConstraints)
        }

        hint.stringValue = open == nil
            ? "Select a bin to see what is in it."
            : "\(open ?? "") is empty. Drag clips here to file them."
        hint.isHidden = !binEntries.isEmpty

        rootTable.reloadData()
        binTable.reloadData()
        applySelection()
    }

    /// Shows the browser's selection in both columns — and the open bin highlighted in
    /// the left one, as the Finder keeps the path to the right column lit.
    func applySelection() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        let open = browser.effectiveOpenBin.map { LibraryEntry.binPrefix + $0 }
        let rootRows = IndexSet(rootEntries.indices.filter {
            browser.selection.contains(rootEntries[$0].id) || rootEntries[$0].id == open
        })
        if rootTable.selectedRowIndexes != rootRows {
            rootTable.selectRowIndexes(rootRows, byExtendingSelection: false)
        }
        let binRows = IndexSet(binEntries.indices.filter { browser.selection.contains(binEntries[$0].id) })
        if binTable.selectedRowIndexes != binRows {
            binTable.selectRowIndexes(binRows, byExtendingSelection: false)
        }
    }

    func entries(of table: NSTableView) -> [LibraryEntry] {
        table === rootTable ? rootEntries : binEntries
    }

    func beginRename(bin: String) {
        guard let row = rootEntries.firstIndex(where: { $0.binName == bin }) else { return }
        rootTable.scrollRowToVisible(row)
        rootTable.editColumn(0, row: row, with: nil, select: true)
    }

    /// Selects everything in the column that has the keyboard — the left one unless
    /// the right one does. ⌘A.
    func selectAllInFocusedColumn() {
        let table = window?.firstResponder === binTable && !binEntries.isEmpty ? binTable : rootTable
        table.selectAll(nil)
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        let entries = entries(of: sender)
        guard entries.indices.contains(sender.clickedRow) else { return }
        let entry = entries[sender.clickedRow]
        if entry.binName != nil {
            // Already open on the right; the double-click takes you into it.
            window?.makeFirstResponder(binTable)
            return
        }
        actions?.libraryOpen(entry)
    }

    /// Where a drop on a row of a column lands.
    fileprivate func bin(forDropOn table: NSTableView, row: Int) -> String? {
        if table === binTable { return browser.effectiveOpenBin }
        guard rootEntries.indices.contains(row) else { return nil }
        return rootEntries[row].binName
    }

    fileprivate func menu(for table: NSTableView, row: Int) -> NSMenu? {
        let entries = entries(of: table)
        let folder = table === binTable ? browser.effectiveOpenBin : nil
        guard entries.indices.contains(row) else {
            return actions?.libraryMenu(clicked: nil, folder: folder)
        }
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        return actions?.libraryMenu(clicked: entries[row], folder: folder)
    }

    /// ← and →: between the columns, as in the Finder.
    fileprivate func moveFocus(from table: NSTableView, right: Bool) -> Bool {
        if right, table === rootTable, browser.effectiveOpenBin != nil, !binEntries.isEmpty {
            window?.makeFirstResponder(binTable)
            if binTable.selectedRowIndexes.isEmpty {
                binTable.selectRowIndexes([0], byExtendingSelection: false)
            }
            return true
        }
        if !right, table === binTable {
            binTable.deselectAll(nil)
            window?.makeFirstResponder(rootTable)
            return true
        }
        return false
    }
}

extension LibraryColumnView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries(of: tableView).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entries = entries(of: tableView)
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("column.name")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ColumnCellView
            ?? ColumnCellView(identifier: identifier)
        cell.textField?.delegate = self
        switch entries[row] {
        case .bin(let name):
            cell.textField?.stringValue = name
            cell.textField?.isEditable = true
            cell.textField?.textColor = Theme.Color.textSecondary
            cell.imageView?.image = LibraryListView.symbol("folder.fill")
            cell.imageView?.contentTintColor = Theme.Color.accent
            cell.chevron.isHidden = false
        case .item(let item):
            cell.textField?.stringValue = item.name
            cell.textField?.isEditable = false
            cell.textField?.textColor = item.isAvailable ? Theme.Color.textSecondary : Theme.Color.textTertiary
            cell.imageView?.image = LibraryListView.symbol(LibraryListView.symbolName(for: item))
            cell.imageView?.contentTintColor = Theme.Color.textSecondary
            cell.chevron.isHidden = true
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let table = notification.object as? NSTableView else { return }
        let entries = entries(of: table)
        let chosen = table.selectedRowIndexes.filter { entries.indices.contains($0) }.map { entries[$0] }
        if table === rootTable {
            // One bin chosen opens it on the right; anything else closes the right.
            let bins = chosen.compactMap(\.binName)
            let newOpen = chosen.count == 1 ? bins.first : nil
            browser.selection = Set(chosen.map(\.id))
            if newOpen != browser.openBin {
                browser.openBin = newOpen
                binEntries = newOpen.map { browser.entries(inBin: $0) } ?? []
                binTable.reloadData()
                hint.stringValue = newOpen == nil
                    ? "Select a bin to see what is in it."
                    : "\(newOpen ?? "") is empty. Drag clips here to file them."
                hint.isHidden = !binEntries.isEmpty
            }
        } else {
            browser.selection = Set(chosen.map(\.id))
        }
        if let last = table.selectedRowIndexes.last, entries.indices.contains(last) {
            browser.anchor = entries[last].id
        }
        actions?.librarySelectionDidChange()
    }

    // MARK: Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let entries = entries(of: tableView)
        guard entries.indices.contains(row), let item = entries[row].item, item.isAvailable,
              item.url != nil || item.reference != nil else { return nil }
        return browser.pasteboardItems(for: [item]).first
    }

    // MARK: Drop target

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let onBinRow = tableView === rootTable && dropOperation == .on
            && rootEntries.indices.contains(row) && rootEntries[row].binName != nil
        let bin = onBinRow ? rootEntries[row].binName : bin(forDropOn: tableView, row: -1)
        if tableView === binTable, browser.effectiveOpenBin == nil { return [] }
        let operation = actions?.libraryDragOperation(info, intoBin: bin) ?? []
        guard !operation.isEmpty else { return [] }
        // Onto the bin row, or the whole column — never between rows.
        tableView.setDropRow(onBinRow ? row : -1, dropOperation: .on)
        return operation
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        actions?.libraryPerformDrop(info, intoBin: bin(forDropOn: tableView, row: row)) ?? false
    }
}

extension LibraryColumnView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = rootTable.row(for: field)
        guard rootEntries.indices.contains(row), let bin = rootEntries[row].binName else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != bin else {
            field.stringValue = bin
            return
        }
        actions?.libraryRenameBin(from: bin, to: newName)
    }
}

/// One column's table, with the library's menus and keys.
final class LibraryColumnTable: NSTableView {

    weak var columnView: LibraryColumnView?

    /// Works on the first click even while another window (the output, Preferences)
    /// is key — like every other control in this window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    override func menu(for event: NSEvent) -> NSMenu? {
        guard let columnView else { return super.menu(for: event) }
        return columnView.menu(for: self, row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let columnView {
            switch (flags, Int(event.keyCode)) {
            case ([], 124):   // →
                if columnView.moveFocus(from: self, right: true) { return }
            case ([], 123):   // ←
                if columnView.moveFocus(from: self, right: false) { return }
            case (.command, 126):   // ⌘↑
                columnView.actions?.libraryGoUp()
                return
            case (.command, 51):    // ⌘⌫: remove from the library
                NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
                return
            case (.command, 125):   // ⌘↓
                let entries = columnView.entries(of: self)
                if selectedRowIndexes.count == 1, entries.indices.contains(selectedRow) {
                    if entries[selectedRow].binName != nil {
                        _ = columnView.moveFocus(from: self, right: true)
                    } else {
                        columnView.actions?.libraryOpen(entries[selectedRow])
                    }
                }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// A column row: icon, name, and a chevron on bins.
final class ColumnCellView: LibraryRowCellView {

    let chevron = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon

        let text = NSTextField(labelWithString: "")
        text.font = Theme.Font.tinyLabel
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.usesSingleLineMode = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)
        textField = text

        chevron.image = LibraryListView.symbol("chevron.right")
        chevron.contentTintColor = Theme.Color.textTertiary
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}
