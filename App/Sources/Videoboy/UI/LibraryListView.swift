//
//  LibraryListView.swift — the library as a sortable table.
//
//  Purpose : Name, kind and duration, sorted by any of them. The grid is for
//            recognising clips by sight; this is for recognising them by name, or for
//            finding the long one, or for seeing what a bin actually contains without
//            counting thumbnails.
//  Inputs   : a LibraryModel, and a search string.
//  Outputs  : the same `onOpen` a thumbnail gives, so a double-click does the same
//             thing in either view.
//  Connects : LibraryPanelBody, LibraryModel.
//  Extend   : a new column is a case on `LibrarySortField` plus a line here. Keep the
//             sort in the MODEL — two views sorting the same library differently is
//             two libraries again.
//
//  ── WHY NSTableView AND NOT A STACK OF ROWS ─────────────────────────────────────
//
//  Because this is exactly what it is for. Sorting by clicking a header, the little
//  arrow that shows which way, keyboard selection, and rows that do not all have to
//  exist at once — all of it is built in, and all of it is fiddly to reproduce. The FX
//  chain is hand-drawn because its rows are tall views full of live controls; these
//  rows are three pieces of text.
//

import AppKit

/// The library as a table.
final class LibraryListView: NSView {

    private let model: LibraryModel
    private let table = NSTableView()
    private let scrollView = NSScrollView()

    /// What is currently shown, after search and sort.
    private var rows: [LibraryItem] = []

    /// Called when a row is double-clicked.
    var onOpen: ((LibraryItem) -> Void)?
    /// Called when a row is right-clicked, so the same menu appears as on a thumbnail.
    var onContextMenu: ((LibraryItem, NSView) -> NSMenu?)?

    /// Called when a header is clicked. The sort belongs to the BROWSER, not to the
    /// library — two panels finding two different clips will want two different orders.
    var onSortChanged: ((LibrarySortField, Bool) -> Void)?

    private var sortField: LibrarySortField = .name
    private var sortAscending = true

    /// The search text this list is filtered by.
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            reload()
        }
    }

    init(model: LibraryModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        table.style = .plain
        table.rowHeight = 18
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self

        for field in LibrarySortField.allCases {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: field.rawValue, ascending: true)
            switch field {
            case .name: column.minWidth = 90; column.width = 150
            case .kind: column.minWidth = 60; column.width = 100
            case .duration: column.minWidth = 46; column.width = 56
            }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: LibrarySortField.name.rawValue, ascending: true)]

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Rebuilds from the model.
    func reload() {
        rows = model.items(matching: searchText, sortedBy: sortField, ascending: sortAscending)
        table.reloadData()
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onOpen?(rows[row])
    }
}

extension LibraryListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let field = LibrarySortField(rawValue: key) else { return }
        sortField = field
        sortAscending = descriptor.ascending
        // Told to the panel, so its GRID sorts the same way — one browser, one order.
        onSortChanged?(field, descriptor.ascending)
        reload()
    }
}

extension LibraryListView: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn,
              let field = LibrarySortField(rawValue: tableColumn.identifier.rawValue) else {
            return nil
        }
        let item = rows[row]

        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let view = NSTableCellView()
                view.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.font = Theme.Font.tinyLabel
                text.lineBreakMode = .byTruncatingMiddle
                text.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(text)
                view.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                return view
            }()

        switch field {
        case .name:
            cell.textField?.stringValue = item.name
            cell.textField?.alignment = .left
        case .kind:
            cell.textField?.stringValue = item.kind
            cell.textField?.alignment = .left
        case .duration:
            cell.textField?.stringValue = item.durationText
            // Right-aligned, because durations are compared by reading down the column
            // and ragged numbers cannot be.
            cell.textField?.alignment = .right
        }
        // An unavailable kind reads as unavailable here too, exactly as its thumbnail
        // does — the list must not make something look loadable that is not.
        cell.textField?.textColor = item.isAvailable
            ? Theme.Color.textSecondary
            : Theme.Color.textTertiary
        return cell
    }
}

extension LibraryListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row), let built = onContextMenu?(rows[row], self) else { return }
        for item in built.items {
            // Items can only belong to one menu, so they are moved across rather than
            // shared — building the menu twice would mean two places deciding what a
            // right-click offers.
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}
