//
//  LibraryBrowser.swift — what one library panel is looking at.
//
//  Purpose : The shared library is one set of clips; each of the three panels browses
//            it separately. This holds what is per-panel — the search, the sort, which
//            bin is open, what is selected — and turns the library into the rows and
//            cells the icon, list and column views draw. It also owns the pasteboard
//            contract, so a drag, a copy and a drop all speak the same format.
//  Inputs   : the LibraryModel, and (for the asset browser's other tabs) a fixed set
//            of items such as the generators.
//  Outputs  : `LibraryEntry` lists; pasteboard items.
//  Connects : LibraryPanelBody (owner), LibraryGridView, LibraryListView,
//            LibraryColumnView, SourcePanelBody (reads what a drag carries).
//  Extend   : a new thing a view needs to know is a query here, so the three views
//            cannot disagree about it.
//
//  ── WHY THE OPEN BIN IS SHARED BY ALL THREE VIEWS ───────────────────────────────
//
//  The Finder's rule: a window is looking at one folder, and the view buttons change
//  how it is drawn, not where you are. Open "Reel A" in icons and switch to columns,
//  and the columns show Reel A open. A per-view position would make the view buttons
//  also silently navigate.
//

import AppKit
import VideoboyCore

/// One cell or row: a bin (drawn as a folder) or an item.
enum LibraryEntry {
    case bin(String)
    case item(LibraryItem)

    /// Unique across both kinds, so one selection set can hold either.
    var id: String {
        switch self {
        case .bin(let name): LibraryEntry.binPrefix + name
        case .item(let item): item.id
        }
    }

    var item: LibraryItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    var binName: String? {
        if case .bin(let name) = self { return name }
        return nil
    }

    /// Bin ids carry a prefix a UUID can never start with.
    static let binPrefix = "bin\u{1F}"
}

/// A panel's view of the shared library.
final class LibraryBrowser {

    let model: LibraryModel

    /// The items of an asset-browser tab that is not the clip library — generators,
    /// configured sources. Nil means this browser is showing the clip library, which
    /// is the only thing with bins.
    var fixedItems: [LibraryItem]?

    /// What is typed in the search field, trimmed.
    var search = ""
    var sortField: LibrarySortField = .name
    var sortAscending = true

    /// The bin the icon and list views are inside, and the column view has open. Nil
    /// is the top level.
    var openBin: String?

    /// Entry ids currently selected. Held here rather than in a view so switching view
    /// style keeps the selection, as it does in the Finder.
    var selection: Set<String> = []

    /// Where a Shift-click range starts: the last entry clicked without Shift.
    var anchor: String?

    init(model: LibraryModel) {
        self.model = model
    }

    /// True when bins are shown as folders — the clip library, not searching.
    ///
    /// A search looks through every bin at once and shows what it finds flat, the way
    /// a Finder search does. Bins in the results would mean opening each one to see
    /// whether it held a match.
    var showsBins: Bool { fixedItems == nil && search.isEmpty }

    /// The open bin, if bins are showing and it still exists.
    var effectiveOpenBin: String? {
        guard showsBins, let openBin, model.binNames.contains(openBin) else { return nil }
        return openBin
    }

    // MARK: - Entries

    /// The top level: bins first (the Finder's "keep folders on top"), then loose
    /// clips. Or, while searching or on another tab, every match, flat.
    func rootEntries() -> [LibraryEntry] {
        if let fixedItems {
            return sortedItems(fixedItems.filter { LibraryModel.matches($0, search: search) })
                .map(LibraryEntry.item)
        }
        guard showsBins else {
            return model.items(matching: search, sortedBy: sortField, ascending: sortAscending)
                .map(LibraryEntry.item)
        }
        let bins = model.binNames.map(LibraryEntry.bin)
        return bins + entries(inBin: nil)
    }

    /// The clips in one bin, or the loose clips when `bin` is nil.
    func entries(inBin bin: String?) -> [LibraryEntry] {
        sortedItems(model.items.filter { $0.bin == bin }).map(LibraryEntry.item)
    }

    /// What the icon and list views show: inside the open bin, or the top level.
    func currentEntries() -> [LibraryEntry] {
        if let bin = effectiveOpenBin { return entries(inBin: bin) }
        return rootEntries()
    }

    private func sortedItems(_ items: [LibraryItem]) -> [LibraryItem] {
        model.sorted(items, by: sortField, ascending: sortAscending)
    }

    /// Looks up an entry by id, wherever it is.
    func entry(withID id: String) -> LibraryEntry? {
        if id.hasPrefix(LibraryEntry.binPrefix) {
            let name = String(id.dropFirst(LibraryEntry.binPrefix.count))
            return model.binNames.contains(name) ? .bin(name) : nil
        }
        if let item = model.item(withID: id) { return .item(item) }
        return fixedItems?.first { $0.id == id }.map(LibraryEntry.item)
    }

    /// The selected items (not bins), in library order.
    var selectedItems: [LibraryItem] {
        let pool = fixedItems ?? model.items
        return pool.filter { selection.contains($0.id) }
    }

    /// The selected bins.
    var selectedBins: [String] {
        model.binNames.filter { selection.contains(LibraryEntry.binPrefix + $0) }
    }

    /// Drops ids that no longer exist, after the library changed underneath.
    func pruneSelection() {
        selection = selection.filter { entry(withID: $0) != nil }
    }

    // MARK: - Pasteboard

    /// What goes on the pasteboard for one item, for a drag or a copy.
    ///
    /// A file writes its URL twice (`.fileURL` for modern readers, the path as a
    /// string for older ones), its marks, and its library id — the id is how a drop
    /// on a bin knows these came from the library and should be MOVED, not added
    /// again. A generator writes only its reference, which a source panel can load.
    static func pasteboardItem(for item: LibraryItem, range: ClosedRange<Double>?) -> NSPasteboardItem {
        let pasteboardItem: NSPasteboardItem
        if let url = item.url {
            pasteboardItem = LibraryItemView.pasteboardItem(for: url, range: range)
        } else {
            pasteboardItem = NSPasteboardItem()
        }
        pasteboardItem.setString(item.id, forType: .videoboyLibraryItem)
        if let reference = item.reference {
            pasteboardItem.setString(reference, forType: .videoboyLibraryReference)
        }
        return pasteboardItem
    }

    /// The library ids on a pasteboard, in order. Empty when the contents came from
    /// outside the app.
    static func libraryIDs(on pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .videoboyLibraryItem) }
    }

    /// Every file URL on a pasteboard.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        return SourcePanelBody.fileURL(from: pasteboard).map { [$0] } ?? []
    }

    /// The types a library view accepts as a drop.
    static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .videoboyLibraryItem]
}

extension NSPasteboard.PasteboardType {
    /// A library entry's id — the part of a drag that says "this came from the library".
    static let videoboyLibraryItem = NSPasteboard.PasteboardType("com.videoboy.library-item")
    /// A non-file item a source panel can load: "generator:3", "isf:<id>", "source:<id>".
    static let videoboyLibraryReference = NSPasteboard.PasteboardType("com.videoboy.library-reference")
}

extension LibraryBrowser {
    /// What a drag or a copy of these items puts on the pasteboard — each with the
    /// marks the library holds for it.
    func pasteboardItems(for items: [LibraryItem]) -> [NSPasteboardItem] {
        items.map { Self.pasteboardItem(for: $0, range: model.markedRange(for: $0.id)) }
    }
}

/// What the icon, list and column views ask of the panel that owns them.
///
/// The views decide WHERE a gesture landed; the panel decides what it MEANS. One
/// place for meaning is what keeps a right-click, a drop or a double-click behaving
/// the same in all three views.
protocol LibraryBrowserActions: AnyObject {
    /// Double-click, or ⌘↓: a bin opens, an item loads into the focused channel.
    func libraryOpen(_ entry: LibraryEntry)
    /// A view changed `browser.selection`.
    func librarySelectionDidChange()
    /// The right-click menu. `clicked` is nil for the background; `folder` is the bin
    /// that background belongs to (nil for the top level).
    func libraryMenu(clicked: LibraryEntry?, folder: String?) -> NSMenu?
    /// Whether a drag may land in a bin (nil: the top level), and as what.
    func libraryDragOperation(_ info: NSDraggingInfo, intoBin bin: String?) -> NSDragOperation
    func libraryPerformDrop(_ info: NSDraggingInfo, intoBin bin: String?) -> Bool
    func libraryRenameBin(from oldName: String, to newName: String)
    /// ⌘↑: out of the open bin.
    func libraryGoUp()
}

/// The drag-source rule every library view shares: anything may be MOVED between
/// bins, but outside the app a drag only ever COPIES — dragging a clip to the Finder
/// must never be a way to lose the file.
enum LibraryDragSource {
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : .copy
    }
}
