//
//  LibraryGridView.swift — the library as icons: thumbnails, and bins as folders.
//
//  Purpose : The Finder's icon view for the library. Clips are thumbnails you can
//            scrub; bins are folders you open with a double-click and file clips into
//            by dropping them on. Click, ⌘-click, ⇧-click, a rubber band on the
//            background and ⌘A select; dragging a selection drags all of it.
//  Inputs   : a LibraryBrowser (what to show, what is selected).
//  Outputs  : LibraryBrowserActions calls — the panel decides what gestures mean.
//  Connects : LibraryPanelBody (owner), LibraryItemView / LibraryFolderView (cells).
//  Extend   : a new cell kind is an NSCollectionViewItem subclass registered here.
//
//  ── WHY NSCollectionView ────────────────────────────────────────────────────────
//
//  SPEC 14.3 asks for it, and it is the control that already does the Mac's grid
//  selection: arrow keys, ⌘A, rubber-banding, and only building the cells on screen.
//  The grid used to be stacks of rows rebuilt wholesale on every change, with no
//  selection at all — which is why none of the Finder's gestures worked in it.
//

import AppKit
import VideoboyCore

/// The icon view.
final class LibraryGridView: NSView {

    let browser: LibraryBrowser
    weak var actions: LibraryBrowserActions?

    let collectionView = LibraryCollectionView()
    private let scrollView = NSScrollView()

    /// What is on screen, in order. Index paths are into this.
    private(set) var entries: [LibraryEntry] = []

    /// The folder a drag is hovering over, drawn as the drop target.
    private weak var dropTargetCell: LibraryCellView?

    /// True while a drag would land in the open folder as a whole.
    private var isWholeViewDropTarget = false {
        didSet {
            guard isWholeViewDropTarget != oldValue else { return }
            layer?.borderWidth = isWholeViewDropTarget ? 2 : 0
            layer?.borderColor = Theme.Color.accent.cgColor
        }
    }

    init(browser: LibraryBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3

        let layout = LeftAlignedFlowLayout()
        layout.itemSize = NSSize(
            width: Theme.Metrics.thumbnailSide,
            height: Theme.Metrics.thumbnailImageHeight + 1 + Theme.Metrics.thumbnailCaptionHeight)
        layout.minimumInteritemSpacing = Theme.Metrics.thumbnailGap
        layout.minimumLineSpacing = Theme.Metrics.thumbnailGap
        layout.sectionInset = NSEdgeInsets(top: 1, left: 0, bottom: 4, right: 0)

        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.grid = self
        collectionView.register(ClipItem.self, forItemWithIdentifier: ClipItem.identifier)
        collectionView.register(BinItem.self, forItemWithIdentifier: BinItem.identifier)

        scrollView.documentView = collectionView
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

        // Drops are taken HERE rather than by the collection view's own machinery,
        // which draws an insertion gap between items — a promise of reordering this
        // library does not make. What a drop can mean is "into this folder" or "into
        // the open one", and this view can tell which from the point alone.
        registerForDraggedTypes(LibraryBrowser.droppedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Contents

    /// Re-reads the browser: what to show, and what is selected.
    ///
    /// A full `reloadData` rebuilds every visible tile in the next layout pass —
    /// 25–33 ms of main thread each time, measured by the in-process sampler during a
    /// 1,000-clip import (it dropped a refresh). So the same entries → the visible
    /// tiles are re-configured in place, which costs nothing like a rebuild. (Batched
    /// `insertItems` was tried for pure additions: its own update bookkeeping cost as
    /// much as the rebuild. Fewer rebuilds is the fix — see LibraryPanelBody.)
    func reload() {
        let old = entries
        let new = browser.currentEntries()
        entries = new
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        if oldIDs == newIDs {
            reconfigureVisible()
        } else {
            collectionView.reloadData()
        }
        applySelection()
    }

    /// Updates the tiles on screen (counts, names, marks) without rebuilding them.
    private func reconfigureVisible() {
        for indexPath in collectionView.indexPathsForVisibleItems() where indexPath.item < entries.count {
            let entry = entries[indexPath.item]
            switch entry {
            case .bin(let name):
                (collectionView.item(at: indexPath) as? BinItem)?.folder
                    .configure(bin: name, count: browser.model.count(inBin: name))
            case .item(let libraryItem):
                (collectionView.item(at: indexPath) as? ClipItem)?.clip
                    .configure(item: libraryItem, marks: browser.model.marks(for: libraryItem.id))
            }
        }
    }

    /// Makes the collection view's selection match the browser's.
    func applySelection() {
        let paths = Set(entries.indices
            .filter { browser.selection.contains(entries[$0].id) }
            .map { IndexPath(item: $0, section: 0) })
        if collectionView.selectionIndexPaths != paths {
            collectionView.selectionIndexPaths = paths
        }
        // Cells that exist but were not told (NSCollectionView only updates the
        // items whose state it changed itself).
        for case let item as LibraryGridItem in collectionView.visibleItems() {
            item.cell.isSelected = browser.selection.contains(item.cell.entry.id)
        }
    }

    /// Reads the collection view's own selection back — after a rubber band, an arrow
    /// key or ⌘A, which it performs itself.
    fileprivate func adoptCollectionSelection() {
        let ids = collectionView.selectionIndexPaths.compactMap { path -> String? in
            entries.indices.contains(path.item) ? entries[path.item].id : nil
        }
        browser.selection = Set(ids)
        if let last = collectionView.selectionIndexPaths.map(\.item).max(),
           entries.indices.contains(last) {
            browser.anchor = entries[last].id
        }
        applySelection()
        actions?.librarySelectionDidChange()
    }

    /// Selects everything in view — what ⌘A does.
    func selectAllEntries() {
        browser.selection = Set(entries.map(\.id))
        applySelection()
        actions?.librarySelectionDidChange()
    }

    /// The cell showing an entry, if it is on screen.
    func cell(for id: String) -> LibraryCellView? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return (collectionView.item(at: IndexPath(item: index, section: 0)) as? LibraryGridItem)?.cell
    }

    /// Scrolls to a bin and puts its name into edit mode.
    func beginRename(bin: String) {
        guard let index = entries.firstIndex(where: { $0.binName == bin }) else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        (collectionView.item(at: path) as? BinItem)?.folder.beginRename()
    }

    // MARK: - Drop target

    /// Where a drop at this point would land: a folder under the pointer, or the open
    /// folder as a whole.
    private func dropTarget(for info: NSDraggingInfo) -> (bin: String?, cell: LibraryCellView?) {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        if let path = collectionView.indexPathForItem(at: point),
           entries.indices.contains(path.item),
           let bin = entries[path.item].binName {
            return (bin, cell(for: entries[path.item].id))
        }
        return (browser.effectiveOpenBin, nil)
    }

    private func updateDropHighlight(_ info: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(for: info)
        let operation = actions?.libraryDragOperation(info, intoBin: target.bin) ?? []
        if dropTargetCell !== target.cell { dropTargetCell?.isDropTarget = false }
        dropTargetCell = operation.isEmpty ? nil : target.cell
        dropTargetCell?.isDropTarget = true
        isWholeViewDropTarget = !operation.isEmpty && target.cell == nil
        return operation
    }

    private func clearDropHighlight() {
        dropTargetCell?.isDropTarget = false
        dropTargetCell = nil
        isWholeViewDropTarget = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = dropTarget(for: sender)
        clearDropHighlight()
        return actions?.libraryPerformDrop(sender, intoBin: target.bin) ?? false
    }
}

// MARK: - Cell gestures

extension LibraryGridView: LibraryCellOwner {

    /// The Finder's press rules. ⌘ toggles one; ⇧ selects the run from the last plain
    /// click; a plain press on something unselected selects only it. A plain press on
    /// something ALREADY selected changes nothing yet — it may be the start of dragging
    /// the whole selection — and narrows to it on release if it was only a click.
    func cellPressed(_ cell: LibraryCellView, with event: NSEvent) {
        takeKeyboard()
        let id = cell.entry.id
        let flags = event.modifierFlags
        if flags.contains(.command) {
            if browser.selection.contains(id) {
                browser.selection.remove(id)
            } else {
                browser.selection.insert(id)
            }
            browser.anchor = id
        } else if flags.contains(.shift) {
            let anchorIndex = browser.anchor.flatMap { anchor in entries.firstIndex { $0.id == anchor } }
                ?? entries.firstIndex { browser.selection.contains($0.id) }
            if let anchorIndex, let clickedIndex = entries.firstIndex(where: { $0.id == id }) {
                let run = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
                browser.selection = Set(run.map { entries[$0].id })
            } else {
                browser.selection = [id]
                browser.anchor = id
            }
        } else if !browser.selection.contains(id) {
            browser.selection = [id]
            browser.anchor = id
        } else {
            return
        }
        applySelection()
        actions?.librarySelectionDidChange()
    }

    func cellReleased(_ cell: LibraryCellView, with event: NSEvent) {
        let id = cell.entry.id
        guard event.modifierFlags.intersection([.command, .shift]).isEmpty,
              browser.selection.contains(id), browser.selection.count > 1 else { return }
        browser.selection = [id]
        browser.anchor = id
        applySelection()
        actions?.librarySelectionDidChange()
    }

    func cellDoubleClicked(_ cell: LibraryCellView) {
        browser.selection = [cell.entry.id]
        browser.anchor = cell.entry.id
        applySelection()
        actions?.libraryOpen(cell.entry)
    }

    /// Drags every selected item — not just the one under the pointer — the way the
    /// Finder drags a selection. Bins stay where they are: they are one level deep and
    /// there is nowhere to drag one TO.
    func cellDragged(_ cell: LibraryCellView, with event: NSEvent) {
        guard cell.entry.item != nil else { return }
        let items = browser.selectedItems.filter { $0.isAvailable && ($0.url != nil || $0.reference != nil) }
        guard !items.isEmpty else { return }
        let writers = browser.pasteboardItems(for: items)

        if let observer = LibraryItemView.onDragStartedForChecks {
            observer(writers)
            return
        }

        // Each dragged image starts where its thumbnail is, when it is on screen, and
        // piles up on the grabbed one when it is not.
        let grabbedFrame = collectionView.convert(cell.bounds, from: cell)
        let dragItems: [NSDraggingItem] = zip(items, writers).enumerated().map { offset, pair in
            let dragItem = NSDraggingItem(pasteboardWriter: pair.1)
            let visible = self.cell(for: pair.0.id)
            let frame = visible.map { collectionView.convert($0.bounds, from: $0) }
                ?? grabbedFrame.offsetBy(dx: CGFloat(offset) * 3, dy: CGFloat(offset) * 3)
            dragItem.setDraggingFrame(frame, contents: (visible ?? cell).snapshot())
            return dragItem
        }
        let session = collectionView.beginDraggingSession(with: dragItems, event: event, source: self)
        session.draggingFormation = items.count > 1 ? .stack : .none
    }

    /// A right-click selects what it lands on first (unless that is already part of
    /// the selection), so the menu always acts on what it appears to.
    func cellMenu(_ cell: LibraryCellView, for event: NSEvent) -> NSMenu? {
        let id = cell.entry.id
        if !browser.selection.contains(id) {
            browser.selection = [id]
            browser.anchor = id
            applySelection()
            actions?.librarySelectionDidChange()
        }
        return actions?.libraryMenu(clicked: cell.entry, folder: browser.effectiveOpenBin)
    }

    func cellRenamed(bin oldName: String, to newName: String) {
        actions?.libraryRenameBin(from: oldName, to: newName)
    }

    func cellMarksChanged(_ cell: LibraryItemView, inPoint: Double?, outPoint: Double?) {
        browser.model.setMarks(inPoint: inPoint, outPoint: outPoint, for: cell.item.id)
    }

    /// The keyboard comes to the grid on a press, so ⌘A, the arrows and ⌘↓ act here —
    /// unless the pointer's thumbnail already has it, which keeps I and O working.
    private func takeKeyboard() {
        guard let window, window.firstResponder !== collectionView else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: collectionView) {
            return
        }
        window.makeFirstResponder(collectionView)
    }
}

extension LibraryGridView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        LibraryDragSource.operationMask(for: context)
    }
}

// MARK: - Data source and delegate

extension LibraryGridView: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let entry = entries[indexPath.item]
        switch entry {
        case .bin(let name):
            let item = collectionView.makeItem(withIdentifier: BinItem.identifier, for: indexPath)
            if let bin = item as? BinItem {
                bin.folder.owner = self
                bin.folder.configure(bin: name, count: browser.model.count(inBin: name))
                bin.folder.isSelected = browser.selection.contains(entry.id)
            }
            return item
        case .item(let libraryItem):
            let item = collectionView.makeItem(withIdentifier: ClipItem.identifier, for: indexPath)
            if let clip = item as? ClipItem {
                clip.clip.owner = self
                clip.clip.configure(item: libraryItem, marks: browser.model.marks(for: libraryItem.id))
                clip.clip.isSelected = browser.selection.contains(entry.id)
            }
            return item
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        adoptCollectionSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        adoptCollectionSelection()
    }
}

// MARK: - Collection view, items, layout

/// The collection view, with the keys the library adds.
final class LibraryCollectionView: NSCollectionView {

    weak var grid: LibraryGridView?

    /// Works on the first click even while another window (the output, Preferences)
    /// is key — like every other control in this window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // I, O and X mark the thumbnail under the pointer, whichever view has the keys.
        if flags.isEmpty, let hovered = HoverScrubView.hovered, hovered.isDescendant(of: self),
           hovered.handleMarkKey(event) {
            return
        }
        if flags == .command, let grid {
            switch Int(event.keyCode) {
            case 126:   // ⌘↑: the enclosing folder
                grid.actions?.libraryGoUp()
                return
            case 51:    // ⌘⌫: remove from the library
                NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
                return
            case 125:   // ⌘↓: open the selection
                if grid.browser.selection.count == 1, let id = grid.browser.selection.first,
                   let entry = grid.browser.entry(withID: id) {
                    grid.actions?.libraryOpen(entry)
                }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// ⌘A. Through the grid so the browser, not just this view, knows.
    override func selectAll(_ sender: Any?) {
        guard let grid else { return super.selectAll(sender) }
        grid.selectAllEntries()
    }

    /// The background's menu: New Bin, Paste — never an item's.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let grid, indexPathForItem(at: point) == nil else { return super.menu(for: event) }
        return grid.actions?.libraryMenu(clicked: nil, folder: grid.browser.effectiveOpenBin)
    }
}

/// An item whose view is a library cell.
protocol LibraryGridItem: NSCollectionViewItem {
    var cell: LibraryCellView { get }
}

/// A clip, generator or source in the grid.
final class ClipItem: NSCollectionViewItem, LibraryGridItem {
    static let identifier = NSUserInterfaceItemIdentifier("library.clip")

    let clip = LibraryItemView()
    var cell: LibraryCellView { clip }

    override func loadView() { view = clip }

    override var isSelected: Bool {
        didSet { clip.isSelected = isSelected }
    }
}

/// A bin, drawn as a folder.
final class BinItem: NSCollectionViewItem, LibraryGridItem {
    static let identifier = NSUserInterfaceItemIdentifier("library.bin")

    let folder = LibraryFolderView()
    var cell: LibraryCellView { folder }

    override func loadView() { view = folder }

    override var isSelected: Bool {
        didSet { folder.isSelected = isSelected }
    }
}

/// A flow layout whose rows start at the left edge and are packed tight.
///
/// The stock flow layout JUSTIFIES full rows, spreading the thumbnails apart as the
/// panel widens. SPEC 14.3 asks for fixed cells packed tightly; a grid whose gaps
/// change with the window is what that rule exists to prevent.
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let original = super.layoutAttributesForElements(in: rect)
        let attributes = original.compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        var rowY: CGFloat = -.greatestFiniteMagnitude
        var x = sectionInset.left
        for attribute in attributes.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) })
        where attribute.representedElementCategory == .item {
            if abs(attribute.frame.minY - rowY) > 1 {
                rowY = attribute.frame.minY
                x = sectionInset.left
            }
            attribute.frame.origin.x = x
            x += attribute.frame.width + minimumInteritemSpacing
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let stock = super.layoutAttributesForItem(at: indexPath) else { return nil }
        // Re-run the row this item is on, so this answer agrees with the one above.
        let row = NSRect(x: 0, y: stock.frame.minY, width: collectionViewContentSize.width,
                         height: stock.frame.height)
        return layoutAttributesForElements(in: row).first { $0.indexPath == indexPath } ?? stock
    }
}
