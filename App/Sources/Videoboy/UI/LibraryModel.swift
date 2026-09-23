//
//  LibraryModel.swift — ONE library, shown in three places.
//
//  Purpose : The clips, the bins, and what everything is sorted and shown as. Held
//            once and shared, so the two sub-mix libraries and the asset browser are
//            three views of the same thing rather than three libraries.
//  Inputs   : imports, drops, bin edits, sort and view changes.
//  Outputs  : `onChanged`, so every view rebuilds together.
//  Connects : LibraryPanelBody (all three of them), PanelSet, ShellController.
//  Extend   : a new fact about a clip is a field on `LibraryItem`; a new way of
//            arranging them is a `ViewStyle`. Do not add a second store.
//
//  ── WHY THE TWO LIBRARY PANELS ARE NOT TWO LIBRARIES ────────────────────────────
//
//  They were: each built its own copy of the same items and kept its own bins, so a
//  folder dropped on the left never appeared on the right, and a bin made in one was
//  invisible in the other. That is a reasonable reading of "two library panels" and it
//  is the wrong one.
//
//  The reason there are two is DESTINATION. The left one sends to A and B, the right
//  to C and D — the panels differ in where a double-click puts the clip, and in
//  nothing else. The contents should be identical, because they are the same library.
//

import AppKit

/// How a library lays its items out.
enum LibraryViewStyle: String, CaseIterable {
    /// Thumbnails in a grid. What you want when you recognise clips by sight.
    case icon
    /// A sortable table with kind and duration. What you want when you recognise
    /// them by name, or need to find the long one.
    case list
    /// Bins down the left, their contents on the right.
    case column

    var symbolName: String {
        switch self {
        case .icon: "square.grid.2x2"
        case .list: "list.bullet"
        case .column: "rectangle.split.2x1"
        }
    }

    var explanation: String {
        switch self {
        case .icon: "Thumbnails"
        case .list: "List, with kind and duration"
        case .column: "Bins beside their contents"
        }
    }
}

/// Which column a list is sorted by.
enum LibrarySortField: String, CaseIterable {
    case name
    case kind
    case duration

    var title: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .duration: "Duration"
        }
    }
}

/// The one library.
final class LibraryModel {

    /// Every clip, in every bin.
    private(set) var items: [LibraryItem] = []

    /// Bins with nothing in them yet.
    ///
    /// Items carry their own bin name, so a bin with contents needs no record — but one
    /// just made and not yet filled would otherwise vanish the moment it was created.
    private(set) var emptyBins: Set<String> = []

    // NOTE: there is no view style or sort here, deliberately.
    //
    // THE CONTENTS ARE SHARED; THE BROWSERS ARE NOT. What makes this one library is
    // that every panel sees the same files and the same bins — drop a folder on the
    // left and it appears on the right. What makes them two browsers is everything
    // else: each has its own search, its own layout and its own sort, because they are
    // being used to find two different clips for two different tracks at the same time.
    //
    // The first version shared the view style too, which meant switching the left panel
    // to a list switched the right one as well — one library, but also one browser,
    // which is not what two panels are for.

    /// Called whenever anything changes, so every view rebuilds together.
    ///
    /// A list of observers rather than one closure: there are three views and they all
    /// need telling. One closure would mean the last panel built silently owning the
    /// notification.
    private var observers: [() -> Void] = []

    func observe(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        for observer in observers { observer() }
    }

    // MARK: - Contents

    func setItems(_ newItems: [LibraryItem]) {
        items = newItems
        notify()
    }

    /// Adds clips, skipping ones already present.
    ///
    /// By FILE PATH, so dropping the same folder twice leaves the library as it was.
    /// It was by NAME, which silently discarded `Reel B/CLIP0001.dv` because
    /// `Reel A/CLIP0001.dv` was already in — the normal case for camera cards, and
    /// exactly what a recursive folder drop produces. Name only for URL-less items.
    func add(_ newItems: [LibraryItem]) {
        func key(_ item: LibraryItem) -> String {
            item.url.map { "path:" + $0.standardizedFileURL.path } ?? "name:" + item.name
        }
        var existing = Set(items.map(key))
        let fresh = newItems.filter { existing.insert(key($0)).inserted }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        notify()
    }

    func moveItem(named name: String, toBin bin: String?) {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return }
        items[index].bin = bin
        notify()
    }

    // MARK: - Bins

    /// Every bin, filled or not.
    var binNames: [String] {
        Array(Set(items.compactMap(\.bin)).union(emptyBins)).sorted()
    }

    /// An unused default name: BIN, then BIN 2, BIN 3...
    func nextBinName() -> String {
        let existing = Set(binNames.map { $0.uppercased() })
        guard existing.contains("BIN") else { return "BIN" }
        var number = 2
        while existing.contains("BIN \(number)") { number += 1 }
        return "BIN \(number)"
    }

    @discardableResult
    func addBin() -> String {
        let name = nextBinName()
        emptyBins.insert(name)
        notify()
        return name
    }

    /// Renames a bin, and every clip in it.
    ///
    /// The items carry the bin NAME rather than an identifier, so a rename has to move
    /// them too — otherwise the old bin keeps its contents and the renamed one is
    /// empty, which looks exactly like the rename having failed.
    func renameBin(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        for index in items.indices where items[index].bin == oldName {
            items[index].bin = newName
        }
        if emptyBins.remove(oldName) != nil { emptyBins.insert(newName) }
        notify()
    }

    // MARK: - Querying

    /// Items matching a search, sorted the way the ASKING PANEL wants them.
    ///
    /// Sort and style are passed in rather than stored, because they belong to the
    /// browser doing the asking, not to the library being asked.
    ///
    /// Matching on the file NAME, the badge and the bin, so "dv" finds both the format
    /// and anything called dv.
    func items(
        matching search: String,
        sortedBy sortField: LibrarySortField = .name,
        ascending: Bool = true
    ) -> [LibraryItem] {
        let matched = items.filter { Self.matches($0, search: search) }
        return sorted(matched, by: sortField, ascending: ascending)
    }

    /// The one search rule, shared by every tab so they cannot disagree about it.
    static func matches(_ item: LibraryItem, search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return true }
        return item.name.lowercased().contains(trimmed)
            || item.badge.lowercased().contains(trimmed)
            || (item.bin?.lowercased().contains(trimmed) ?? false)
    }

    func sorted(
        _ subset: [LibraryItem], by sortField: LibrarySortField, ascending: Bool
    ) -> [LibraryItem] {
        let ordered = subset.sorted { left, right in
            switch sortField {
            case .name:
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .kind:
                // Within a kind, by name — otherwise every DV clip is in arbitrary
                // order, which is worse than not sorting at all.
                if left.badge == right.badge {
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
                return left.badge < right.badge
            case .duration:
                // Unknown durations sort last whichever way the arrow points: they are
                // absent rather than zero, and burying them under a pile of clips
                // showing "—" is not what "sort by duration" means.
                switch (left.duration, right.duration) {
                case (nil, nil):
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?): return a < b
                }
            }
        }
        return ascending ? ordered : ordered.reversed()
    }
}
