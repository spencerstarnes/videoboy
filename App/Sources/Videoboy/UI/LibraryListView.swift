//
//  LibraryListView.swift — the library as a sortable outline.
//
//  Purpose : The Finder's list view. Name, kind and duration, sorted by clicking a
//            header; bins are folder rows with a disclosure triangle, so their
//            contents can be seen without leaving the list. Click, ⇧-click, ⌘-click
//            and ⌘A select; dragging drags every selected row; dropping on a folder
//            row files the clips in that bin.
//  Inputs   : a LibraryBrowser.
//  Outputs  : LibraryBrowserActions calls — the same ones the icon view makes, so a
//             double-click or a right-click means the same thing in either.
//  Connects : LibraryPanelBody, LibraryBrowser.
//  Extend   : a new column is a case on `LibrarySortField` plus a line here. Keep the
//             sort in the BROWSER — the icon view sorts by it too.
//
//  ── WHY NSOutlineView ───────────────────────────────────────────────────────────
//
//  It is exactly this control: sortable headers, disclosure rows, the Mac's selection
//  rules, row drags, drop-on-row highlighting, in-place renaming, and rows that are
//  only built when on screen. The list used to be a flat NSTableView inside a second
//  scroll view, pinned to 160 points tall — which is why it stopped a third of the way
//  down the panel with its last row cut in half, and why the same clip in two bins
//  appeared twice with nothing to say which was which.
//

import AppKit

/// The list view.
final class LibraryListView: NSView {

    let browser: LibraryBrowser
    weak var actions: LibraryBrowserActions?

    let outline = LibraryOutlineView()
    private let scrollView = NSScrollView()

    /// The rows as objects, because NSOutlineView tells rows apart by identity.
    private var roots: [ListNode] = []

    /// Which bins are open, kept across reloads — a rebuild must not fold everything
    /// shut under someone who was looking inside a bin.
    private var expandedBins: Set<String> = []

    /// True while the view is applying the browser's selection, so the change it
    /// makes is not reported back as the user's.
    private var isApplyingSelection = false

    init(browser: LibraryBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        outline.list = self
        outline.style = .plain
        outline.rowHeight = 18
        outline.indentationPerLevel = 12
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.setDraggingSourceOperationMask(LibraryDragSource.operationMask(for: .outsideApplication), forLocal: false)
        outline.setDraggingSourceOperationMask(LibraryDragSource.operationMask(for: .withinApplication), forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.registerForDraggedTypes(LibraryBrowser.droppedTypes)

        for field in LibrarySortField.allCases {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            switch field {
            case .name: column.minWidth = 90; column.width = 170; column.resizingMask = .autoresizingMask
            case .kind: column.minWidth = 60; column.width = 100
            case .duration: column.minWidth = 46; column.width = 56
            }
            outline.addTableColumn(column)
            if field == .name { outline.outlineTableColumn = column }
        }
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Contents

    /// Rebuilds from the browser, keeping which bins are open and what is selected.
    func reload() {
        outline.sortDescriptors = [NSSortDescriptor(
            key: browser.sortField.rawValue, ascending: browser.sortAscending)]
        roots = browser.currentEntries().map { entry in
            let node = ListNode(entry: entry)
            if let bin = entry.binName {
                node.children = browser.entries(inBin: bin).map { ListNode(entry: $0, parent: node) }
            }
            return node
        }
        expandedBins = expandedBins.filter { browser.model.binNames.contains($0) }
        outline.reloadData()
        for node in roots where node.entry.binName.map(expandedBins.contains) == true {
            outline.expandItem(node)
        }
        applySelection()
    }

    /// Makes the rows' selection match the browser's.
    func applySelection() {
        var rows = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? ListNode, browser.selection.contains(node.entry.id) {
                rows.insert(row)
            }
        }
        guard rows != outline.selectedRowIndexes else { return }
        isApplyingSelection = true
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
    }

    /// Puts a bin's name into edit mode.
    func beginRename(bin: String) {
        guard let node = roots.first(where: { $0.entry.binName == bin }) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    /// The node under a row, for the self-QA and the menus.
    func entry(atRow row: Int) -> LibraryEntry? {
        (outline.item(atRow: row) as? ListNode)?.entry
    }

    /// The row an entry is on, if it is showing.
    func row(for id: String) -> Int? {
        (0..<outline.numberOfRows).first { entry(atRow: $0)?.id == id }
    }

    /// Opens or closes a bin row.
    func setExpanded(_ expanded: Bool, bin: String) {
        guard let node = roots.first(where: { $0.entry.binName == bin }) else { return }
        if expanded { outline.expandItem(node) } else { outline.collapseItem(node) }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard let node = outline.item(atRow: row) as? ListNode else { return }
        if node.entry.binName != nil {
            // A folder row opens in place, as it does in the Finder's list view.
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
            return
        }
        actions?.libraryOpen(node.entry)
    }

    /// Which bin a drop on this row (or on nothing) lands in.
    fileprivate func bin(forDropOn item: Any?) -> String? {
        guard let node = item as? ListNode else { return browser.effectiveOpenBin }
        if let bin = node.entry.binName { return bin }
        // A clip inside a bin means that bin; a loose clip means the top level.
        return node.parent?.entry.binName ?? browser.effectiveOpenBin
    }

    fileprivate func menu(forRow row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? ListNode else {
            return actions?.libraryMenu(clicked: nil, folder: browser.effectiveOpenBin)
        }
        // A right-click selects the row it lands on unless it is already selected,
        // so the menu acts on what it appears to.
        if !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        return actions?.libraryMenu(clicked: node.entry, folder: bin(forDropOn: node))
    }
}

/// A row's cell in the list and column views.
///
/// The row answers a press, not its icon or label: in a window that is not key, AppKit
/// asks the view under the pointer whether it takes the first click, and an icon says
/// no — so the click was spent activating the window and the row was not selected.
/// The press then goes up to the table, which selects. A name being renamed keeps its
/// clicks, so the caret can be placed.
class LibraryRowCellView: NSTableCellView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSText { return hit }
        if let field = hit as? NSTextField, field.currentEditor() != nil { return hit }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One row: an entry, and its children when it is a bin.
final class ListNode: NSObject {
    let entry: LibraryEntry
    weak var parent: ListNode?
    var children: [ListNode] = []

    init(entry: LibraryEntry, parent: ListNode? = nil) {
        self.entry = entry
        self.parent = parent
    }
}

extension LibraryListView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ListNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ListNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ListNode)?.entry.binName != nil
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let field = LibrarySortField(rawValue: key) else { return }
        guard field != browser.sortField || descriptor.ascending != browser.sortAscending else { return }
        browser.sortField = field
        browser.sortAscending = descriptor.ascending
        reload()
    }

    // MARK: Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let libraryItem = (item as? ListNode)?.entry.item, libraryItem.isAvailable,
              libraryItem.url != nil || libraryItem.reference != nil else { return nil }
        return browser.pasteboardItems(for: [libraryItem]).first
    }

    // MARK: Drop target

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let bin = bin(forDropOn: item)
        let operation = actions?.libraryDragOperation(info, intoBin: bin) ?? []
        guard !operation.isEmpty else { return [] }
        // Retarget onto the folder row itself, or onto the whole list for the open
        // folder — never between rows, which would promise a reordering.
        let binNode = roots.first { $0.entry.binName == bin && bin != browser.effectiveOpenBin }
        outlineView.setDropItem(binNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        actions?.libraryPerformDrop(info, intoBin: bin(forDropOn: item)) ?? false
    }
}

extension LibraryListView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ListNode, let tableColumn,
              let field = LibrarySortField(rawValue: tableColumn.identifier.rawValue) else { return nil }

        let identifier = tableColumn.identifier
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier, withIcon: field == .name)
        cell.textField?.delegate = self

        let entry = node.entry
        let available = entry.item?.isAvailable ?? true
        switch (field, entry) {
        case (.name, .bin(let name)):
            cell.textField?.stringValue = name
            cell.imageView?.image = Self.symbol("folder.fill")
            cell.imageView?.contentTintColor = Theme.Color.accent
            // Folder names can be edited in place (Rename, or a click on a selected
            // name); clip names are the file's and cannot.
            cell.textField?.isEditable = true
        case (.name, .item(let item)):
            cell.textField?.stringValue = item.name
            cell.imageView?.image = Self.symbol(Self.symbolName(for: item))
            cell.imageView?.contentTintColor = Theme.Color.textSecondary
            cell.textField?.isEditable = false
        case (.kind, .bin):
            cell.textField?.stringValue = "Bin"
        case (.kind, .item(let item)):
            cell.textField?.stringValue = item.kind
        case (.duration, .bin(let name)):
            let count = browser.model.count(inBin: name)
            cell.textField?.stringValue = "\(count) item\(count == 1 ? "" : "s")"
        case (.duration, .item(let item)):
            cell.textField?.stringValue = item.durationText
        }
        // Right-aligned, because durations are compared by reading down the column
        // and ragged numbers cannot be.
        cell.textField?.alignment = field == .duration ? .right : .left
        // An unavailable kind reads as unavailable here too, exactly as its thumbnail
        // does — the list must not make something look loadable that is not.
        cell.textField?.textColor = available ? Theme.Color.textSecondary : Theme.Color.textTertiary
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        var ids = Set<String>()
        for row in outline.selectedRowIndexes {
            if let entry = entry(atRow: row) { ids.insert(entry.id) }
        }
        browser.selection = ids
        if let last = outline.selectedRowIndexes.last, let entry = entry(atRow: last) {
            browser.anchor = entry.id
        }
        actions?.librarySelectionDidChange()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let bin = (notification.userInfo?["NSObject"] as? ListNode)?.entry.binName {
            expandedBins.insert(bin)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let bin = (notification.userInfo?["NSObject"] as? ListNode)?.entry.binName {
            expandedBins.remove(bin)
        }
    }

    // MARK: Cells

    /// A row's cell: text, and an icon in the name column.
    static func makeCell(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let view = LibraryRowCellView()
        view.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = Theme.Font.tinyLabel
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.usesSingleLineMode = true
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        view.textField = text

        var leading = text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2)
        if withIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            view.addSubview(icon)
            view.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14)
            ])
            leading = text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    }

    /// A small icon saying what kind of thing a row is — a symbol rather than a
    /// decoded frame, because a list can be long and decoding is main-thread time.
    static func symbolName(for item: LibraryItem) -> String {
        if item.generatorKind != nil || item.isfModuleID != nil { return "sparkles" }
        if item.configuredSourceID != nil { return "video" }
        if item.badge == "SEQ" { return "photo.stack" }
        return "film"
    }
}

extension LibraryListView: NSTextFieldDelegate {
    /// A folder row's name was edited in place.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = outline.row(for: field)
        guard let bin = entry(atRow: row)?.binName else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != bin else {
            field.stringValue = bin
            return
        }
        actions?.libraryRenameBin(from: bin, to: newName)
    }
}

/// The outline, with the library's keys and menus.
final class LibraryOutlineView: NSOutlineView {

    weak var list: LibraryListView?

    /// Works on the first click even while another window (the output, Preferences)
    /// is key — like every other control in this window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    override func menu(for event: NSEvent) -> NSMenu? {
        guard let list else { return super.menu(for: event) }
        return list.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, let list {
            switch Int(event.keyCode) {
            case 126:   // ⌘↑: the enclosing folder
                list.actions?.libraryGoUp()
                return
            case 51:    // ⌘⌫: remove from the library
                NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
                return
            case 125:   // ⌘↓: open the selection
                if selectedRowIndexes.count == 1, let entry = list.entry(atRow: selectedRow) {
                    if let bin = entry.binName {
                        list.setExpanded(true, bin: bin)
                    } else {
                        list.actions?.libraryOpen(entry)
                    }
                }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}
