//
//  LibraryModel.swift — ONE library, shown in three places.
//
//  Purpose : The clips, the bins, and the marks on them. Held once and shared, so the
//            two sub-mix libraries and the asset browser are three views of the same
//            thing rather than three libraries.
//  Inputs   : imports, drops, pastes, bin edits.
//  Outputs  : `observe`, so every view rebuilds together.
//  Connects : LibraryPanelBody (all three of them), LibraryBrowser, PanelSet,
//            ShellController.
//  Extend   : a new fact about a clip is a field on `LibraryItem`; a new way of
//            arranging them is a `LibraryViewStyle`. Do not add a second store.
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
//  ── WHY ITEMS HAVE AN ID AND NOT JUST A PATH ────────────────────────────────────
//
//  A library entry is a REFERENCE to a file, the way a clip in an editor's bin is. Copy
//  a clip and paste it into another bin and there are two entries for one file — which
//  is what copy and paste means everywhere else on a Mac. Selection, moves and marks
//  all need to say WHICH of the two, so each entry carries its own identifier.
//

import AppKit
import VideoboyCore

/// One entry in a library: a clip, a generator, a configured source.
struct LibraryItem {
    /// Which entry this is. Unique within the library, stable for the entry's life.
    ///
    /// A fresh UUID for a clip, because the same file may be in two bins. Built-in
    /// things (a generator, a configured source) use a fixed id derived from what they
    /// are, so a grid rebuilt from scratch still knows which one was selected.
    var id: String

    /// Display name, e.g. "bars.dv".
    let name: String
    /// Short type badge: DV, MOV, MPG, GEN, SVG, SCR, IP, CAP, EMU, IMG.
    let badge: String
    /// False for item kinds whose source module is not built yet.
    let isAvailable: Bool
    /// The file on disk, for items that have one. Nil for generators and for the
    /// kinds that are advertised but not built.
    let url: URL?

    /// The `ConfiguredSource.id` this item represents, for a Sources-tab tile.
    var configuredSourceID: String?

    /// The module ID of an ISF generator this item stands for (ISF-PLAN M9).
    var isfModuleID: String?

    /// The built-in generator this item stands for.
    var generatorKind: GeneratorKind?

    /// A still picture for items that have no file to decode one from — the
    /// generators, rendered once by `GeneratorThumbnails`.
    var thumbnail: NSImage?

    /// Which bin this item sits in. Nil means the top level of the library.
    ///
    /// A plain string rather than a bin object: bins are one level deep and a name is
    /// the whole of what distinguishes one from another.
    var bin: String?

    /// How long the clip runs, in seconds. Nil when it is not a clip, or not yet read.
    ///
    /// Nil rather than zero: a generator has no duration, and a zero would sort it in
    /// among the shortest clips and read as a clip of no length.
    var duration: Double?

    /// What kind of thing this is, spelled out for the list view.
    ///
    /// The badge is three letters because it goes on a thumbnail; a list column has
    /// room for the word, and "QuickTime movie" is more use than "MOV" to someone
    /// scanning for the odd one out.
    var kind: String {
        switch badge.uppercased() {
        case "DV": "DV video"
        case "MOV": "QuickTime movie"
        case "MPG", "M2V": "MPEG video"
        case "SEQ": "Image sequence"
        case "GEN": "Generator"
        case "ISF": "ISF generator"
        case "SVG": "Vector"
        case "SCR": "Screen capture"
        case "IP": "Network feed"
        case "CAP": "Capture device"
        case "FW": "DV deck"
        case "EMU": "Emulator"
        case "IMG": "Still image"
        default: badge
        }
    }

    /// The duration as a list shows it: m:ss, or an em dash when there is none.
    var durationText: String {
        guard let duration, duration > 0 else { return "—" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// What a drag or a copy of a non-file item carries, so a source panel can load
    /// it: "generator:3", "isf:<module>", "source:<id>". Nil for a file, whose URL is
    /// what travels.
    var reference: String? {
        if let generatorKind { return "generator:\(generatorKind.rawValue)" }
        if let isfModuleID { return "isf:\(isfModuleID)" }
        if let configuredSourceID { return "source:\(configuredSourceID)" }
        return nil
    }

    init(
        name: String, badge: String, isAvailable: Bool,
        url: URL? = nil, bin: String? = nil, duration: Double? = nil,
        configuredSourceID: String? = nil, id: String? = nil
    ) {
        self.id = id ?? configuredSourceID.map { "source:\($0)" } ?? UUID().uuidString
        self.name = name
        self.badge = badge
        self.isAvailable = isAvailable
        self.url = url
        self.bin = bin
        self.duration = duration
        self.configuredSourceID = configuredSourceID
    }
}

/// How a library lays its items out.
enum LibraryViewStyle: String, CaseIterable {
    /// Thumbnails in a grid, bins as folders you open. What you want when you
    /// recognise clips by sight.
    case icon
    /// A sortable outline, bins as disclosure rows. What you want when you recognise
    /// them by name, or need to find the long one.
    case list
    /// The Finder's columns: bins on the left, the chosen bin's clips beside them.
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
        case .icon: "Icons"
        case .list: "List, with kind and duration"
        case .column: "Columns — bins beside their contents"
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

    /// In and out points by item id, 0...1 of the clip.
    ///
    /// Here and not on the thumbnail: thumbnails are recycled as the grid scrolls and
    /// rebuilt when it changes, and marks kept on a view went with it — or, worse,
    /// turned up on whichever clip the view was reused for.
    private var marks: [String: (inPoint: Double?, outPoint: Double?)] = [:]

    // NOTE: there is no view style, sort or selection here, deliberately.
    //
    // THE CONTENTS ARE SHARED; THE BROWSERS ARE NOT. What makes this one library is
    // that every panel sees the same files and the same bins. What makes them separate
    // browsers is everything else — see LibraryBrowser.

    /// A list of observers rather than one closure: there are three views and they all
    /// need telling.
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

    func item(withID id: String) -> LibraryItem? {
        items.first { $0.id == id }
    }

    /// Adds clips, skipping ones already in the same bin.
    ///
    /// By FILE PATH, so dropping the same folder twice leaves the library as it was.
    /// It was by NAME, which silently discarded `Reel B/CLIP0001.dv` because
    /// `Reel A/CLIP0001.dv` was already in — the normal case for camera cards. Name
    /// only for URL-less items.
    ///
    /// Per BIN, because a clip may be filed in two bins on purpose (copy it into a
    /// second one) — what must not happen is the same bin holding it twice from a
    /// repeated drop.
    ///
    /// - Returns: the ids of what was actually added.
    @discardableResult
    func add(_ newItems: [LibraryItem]) -> [String] {
        func key(_ item: LibraryItem) -> String {
            let file = item.url.map { "path:" + $0.standardizedFileURL.path } ?? "name:" + item.name
            return file + "|" + (item.bin ?? "")
        }
        var existing = Set(items.map(key))
        let fresh = newItems.filter { existing.insert(key($0)).inserted }
        guard !fresh.isEmpty else { return [] }
        items.append(contentsOf: fresh)
        for bin in Set(fresh.compactMap(\.bin)) { emptyBins.remove(bin) }
        notify()
        return fresh.map(\.id)
    }

    /// Files entries into a bin, or takes them out of one when `bin` is nil.
    func moveItems(_ ids: [String], toBin bin: String?) {
        let wanted = Set(ids)
        var changed = false
        for index in items.indices where wanted.contains(items[index].id) && items[index].bin != bin {
            items[index].bin = bin
            changed = true
        }
        guard changed else { return }
        if let bin { emptyBins.remove(bin) }
        notify()
    }

    /// Kept for the callers that only know a name. Moves the first entry so called.
    func moveItem(named name: String, toBin bin: String?) {
        guard let item = items.first(where: { $0.name == name }) else { return }
        if let bin, !binNames.contains(bin) { emptyBins.insert(bin) }
        moveItems([item.id], toBin: bin)
    }

    /// Puts a second entry for each clip into a bin — what Paste does with clips that
    /// were copied from the library itself. Marks come along, as they would with any copy.
    ///
    /// - Returns: the new entries' ids, so the paste can select what it made.
    @discardableResult
    func duplicateItems(_ ids: [String], intoBin bin: String?) -> [String] {
        var made: [LibraryItem] = []
        for id in ids {
            guard var copy = item(withID: id) else { continue }
            copy.id = UUID().uuidString
            copy.bin = bin
            marks[copy.id] = marks[id]
            made.append(copy)
        }
        guard !made.isEmpty else { return [] }
        items.append(contentsOf: made)
        if let bin { emptyBins.remove(bin) }
        notify()
        return made.map(\.id)
    }

    /// Takes entries out of the library. The files on disk are never touched.
    func removeItems(_ ids: Set<String>) {
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        for id in ids { marks[id] = nil }
        guard items.count != before else { return }
        notify()
    }

    // MARK: - Marks

    func marks(for id: String) -> (inPoint: Double?, outPoint: Double?) {
        marks[id] ?? (nil, nil)
    }

    /// Records marks WITHOUT notifying: they are drawn by the thumbnail that set them,
    /// and rebuilding three libraries on every I and O would be a hitch per keypress.
    func setMarks(inPoint: Double?, outPoint: Double?, for id: String) {
        marks[id] = (inPoint == nil && outPoint == nil) ? nil : (inPoint, outPoint)
    }

    /// The marked range for an entry, or nil when the whole clip is wanted.
    ///
    /// One mark counts: marking only an in point means "from here to the end", which
    /// is what every editor does.
    func markedRange(for id: String) -> ClosedRange<Double>? {
        let current = marks(for: id)
        guard current.inPoint != nil || current.outPoint != nil else { return nil }
        return (current.inPoint ?? 0)...(current.outPoint ?? 1)
    }

    // MARK: - Bins

    /// Every bin, filled or not.
    var binNames: [String] {
        Array(Set(items.compactMap(\.bin)).union(emptyBins))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// How many entries a bin holds.
    func count(inBin bin: String) -> Int {
        items.reduce(0) { $0 + ($1.bin == bin ? 1 : 0) }
    }

    /// An unused name: "untitled bin", then "untitled bin 2" — the Finder's pattern.
    func nextBinName(base: String = "untitled bin") -> String {
        let existing = Set(binNames.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var number = 2
        while existing.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Makes an empty bin with an unused name and returns the name.
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
    /// empty, which looks exactly like the rename having failed. Renaming onto an
    /// existing bin merges the two, as dropping a folder of the same name already does.
    func renameBin(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard oldName != trimmed, !trimmed.isEmpty else { return }
        for index in items.indices where items[index].bin == oldName {
            items[index].bin = trimmed
        }
        if emptyBins.remove(oldName) != nil, count(inBin: trimmed) == 0 {
            emptyBins.insert(trimmed)
        }
        notify()
    }

    /// Deletes a bin. Its clips go back to the top level rather than out of the
    /// library: a bin is a way of arranging clips, and throwing one away should not
    /// throw away what was arranged in it.
    func deleteBin(_ name: String) {
        emptyBins.remove(name)
        for index in items.indices where items[index].bin == name {
            items[index].bin = nil
        }
        notify()
    }

    // MARK: - Querying

    /// The one search rule, shared by every tab so they cannot disagree about it.
    ///
    /// Matching on the file NAME, the badge and the bin, so "dv" finds both the format
    /// and anything called dv, and a bin's name finds everything in it.
    static func matches(_ item: LibraryItem, search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return true }
        return item.name.lowercased().contains(trimmed)
            || item.badge.lowercased().contains(trimmed)
            || (item.bin?.lowercased().contains(trimmed) ?? false)
    }

    /// Items matching a search, sorted the way the ASKING PANEL wants them.
    func items(
        matching search: String,
        sortedBy sortField: LibrarySortField = .name,
        ascending: Bool = true
    ) -> [LibraryItem] {
        sorted(items.filter { Self.matches($0, search: search) }, by: sortField, ascending: ascending)
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
                // absent rather than zero.
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
