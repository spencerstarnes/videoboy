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

    /// Frames in the clip and its rate, measured once at import (`ClipProbe`) and kept
    /// in the catalog, so loading never has to count them. Nil until measured.
    var frameCount: Int?
    var frameRate: Double?

    /// A Finder bookmark to the file, made at import off the main thread, so a moved or
    /// renamed file can be found again. Nil for items that were never imported.
    var bookmark: Data?

    /// The file's standardised path, when whoever made the entry already worked it out
    /// off the main thread (the import job does). Saves the library computing it for
    /// each new entry while a show is on.
    var standardPath: String?
    /// The linked optimized file and the canvas it was made for (0.4.10).
    var optimizedPath: String?
    var optimizedCanvas: String?

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

extension LibraryItem {
    /// An entry read back from the catalog.
    init(_ clip: CatalogClip) {
        self.init(name: clip.name, badge: clip.badge, isAvailable: true,
                  url: URL(fileURLWithPath: clip.path, isDirectory: clip.badge == "SEQ"),
                  bin: clip.bin, duration: clip.duration, id: clip.id)
        frameCount = clip.frameCount
        frameRate = clip.frameRate
        bookmark = clip.bookmark
        optimizedPath = clip.optimizedPath
        optimizedCanvas = clip.optimizedCanvas
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

    /// Every clip, in every bin. Any change — even to one entry's bin — drops the
    /// cached bin counts.
    private(set) var items: [LibraryItem] = [] {
        didSet { binCounts = nil }
    }

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

    // MARK: - The catalog
    //
    // Everything below is written through to it as it changes, so the library a
    // performer builds is the library they come back to. Without a catalog (the
    // self-QA's windows, or a catalog another copy of the app holds) the library works
    // exactly as before, in memory.

    private(set) var catalog: Catalog?
    /// Library order, as stored.
    private var positions: [String: Int] = [:]
    private var nextPosition = 0

    /// Connects the saved catalog. A catalog that holds clips REPLACES what the library
    /// started with; an empty one is seeded from it (the first launch).
    func attach(_ catalog: Catalog) {
        self.catalog = catalog
        let stored = catalog.loadClips()
        if stored.isEmpty {
            for item in items { position(for: item.id) }
            persist(items.map(\.id))
            persistEmptyBins()
            Log.info(.app, "catalog is new; seeded with \(items.count) clips")
        } else {
            items = stored.map(LibraryItem.init)
            marks = [:]
            positions = [:]
            for clip in stored {
                positions[clip.id] = clip.position
                if clip.inPoint != nil || clip.outPoint != nil {
                    marks[clip.id] = (clip.inPoint, clip.outPoint)
                }
            }
            nextPosition = (stored.map(\.position).max() ?? -1) + 1
            emptyBins = Set(catalog.loadEmptyBins())
            Log.info(.app, "catalog loaded: \(stored.count) clips, \(binNames.count) bins")
            fillDurations()
            notify()
        }
    }

    /// Each entry's standardised file path, computed once. A clip's URL never changes,
    /// and `standardizedFileURL` allocates: recomputing it for every entry on every
    /// batch of a 1,000-clip import cost up to 33 ms of main thread a batch.
    private var pathKeys: [String: String] = [:]

    /// The standardised path of an entry's file, cached by id; nil for non-file items.
    private func pathKey(_ item: LibraryItem) -> String? {
        if let known = pathKeys[item.id] { return known }
        guard let url = item.url else { return nil }
        let key = item.standardPath ?? url.standardizedFileURL.path
        pathKeys[item.id] = key
        return key
    }

    @discardableResult
    private func position(for id: String) -> Int {
        if let known = positions[id] { return known }
        positions[id] = nextPosition
        nextPosition += 1
        return nextPosition - 1
    }

    /// Writes these entries' current state to the catalog. Entries without a file
    /// (generators, sources) are not library clips and are not stored.
    private func persist<S: Sequence>(_ ids: S) where S.Element == String {
        guard let catalog else { return }
        let wanted = Set(ids)
        let records: [CatalogClip] = items.compactMap { item in
            guard wanted.contains(item.id), let url = item.url else { return nil }
            let mark = marks[item.id]
            return CatalogClip(
                id: item.id, path: url.path, bookmark: item.bookmark, name: item.name,
                badge: item.badge, bin: item.bin, duration: item.duration,
                frameCount: item.frameCount, frameRate: item.frameRate,
                inPoint: mark?.inPoint, outPoint: mark?.outPoint, position: position(for: item.id),
                optimizedPath: item.optimizedPath, optimizedCanvas: item.optimizedCanvas)
        }
        catalog.save(records)
    }

    private func persistEmptyBins() {
        catalog?.saveEmptyBins(emptyBins)
    }

    /// Clip ids by standardised file path (the first entry for a file) — for Import
    /// mode, which shows and stores marks for clips already in the library.
    func idsByPath() -> [String: String] {
        var ids: [String: String] = [:]
        for item in items {
            if let key = pathKey(item), ids[key] == nil { ids[key] = item.id }
        }
        return ids
    }

    /// The standardised path of every clip's file — handed to Import mode's background
    /// queue, which works out DUP badges from it (paths are cached, so this is cheap).
    func filePaths() -> [String] {
        items.compactMap { pathKey($0) }
    }

    /// The measured frame count for a file, when the library has one — handed to the
    /// decoder so a long MPEG stream is not counted again on load.
    func frameCount(forPath path: String) -> Int? {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.first { $0.frameCount != nil && pathKey($0) == standard }?.frameCount
    }

    func observe(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        let start = notifyCostsForChecks != nil ? CACurrentMediaTime() : 0
        for observer in observers { observer() }
        if notifyCostsForChecks != nil {
            notifyCostsForChecks?.append((CACurrentMediaTime() - start) * 1000)
        }
    }

    /// Milliseconds each notification took (every view rebuilding), while a check
    /// sets this non-nil. Nil in normal use: no cost, no growth.
    var notifyCostsForChecks: [Double]?

    // MARK: - Contents

    func setItems(_ newItems: [LibraryItem]) {
        items = newItems
        fillDurations()
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
    /// - Parameter measuresDurations: false when the caller measures them itself (the
    ///   import job does, off the main thread), so no file is probed twice.
    @discardableResult
    func add(_ newItems: [LibraryItem], measuresDurations: Bool = true) -> [String] {
        func key(_ item: LibraryItem) -> String {
            let file = pathKey(item).map { "path:" + $0 } ?? "name:" + item.name
            return file + "|" + (item.bin ?? "")
        }
        var existing = Set(items.map(key))
        let fresh = newItems.filter { existing.insert(key($0)).inserted }
        guard !fresh.isEmpty else { return [] }
        items.append(contentsOf: fresh)
        for bin in Set(fresh.compactMap(\.bin)) { emptyBins.remove(bin) }
        for item in fresh { position(for: item.id) }
        persist(fresh.map(\.id))
        persistEmptyBins()
        if measuresDurations {
            fillDurations()
        } else {
            for item in fresh { if let key = pathKey(item) { askedPaths.insert(key) } }
        }
        notify()
        return fresh.map(\.id)
    }

    /// Files entries into a bin, or takes them out of one when `bin` is nil.
    func moveItems(_ ids: [String], toBin bin: String?) {
        let wanted = Set(ids)
        var changed: [String] = []
        for index in items.indices where wanted.contains(items[index].id) && items[index].bin != bin {
            items[index].bin = bin
            changed.append(items[index].id)
        }
        guard !changed.isEmpty else { return }
        if let bin { emptyBins.remove(bin) }
        persist(changed)
        persistEmptyBins()
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
        for item in made { position(for: item.id) }
        persist(made.map(\.id))
        persistEmptyBins()
        notify()
        return made.map(\.id)
    }

    /// Takes entries out of the library. The files on disk are never touched.
    func removeItems(_ ids: Set<String>) {
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        for id in ids { marks[id] = nil; positions[id] = nil; pathKeys[id] = nil }
        guard items.count != before else { return }
        catalog?.delete(ids: Array(ids))
        notify()
    }

    // MARK: - Durations
    //
    // An imported clip arrives with no length: the Duration column read "—" for every
    // one of them. Measuring means opening the file, which is I/O, so it happens on a
    // background queue and the column fills in as each answer comes back. Measured
    // once per FILE — the same clip in three bins is asked about once.

    /// Lengths already measured, by standardised path.
    private var measuredDurations: [String: Double] = [:]
    /// Paths being measured now, or found unreadable — not asked about again.
    private var askedPaths: Set<String> = []
    private let durationQueue = DispatchQueue(label: "videoboy.library.durations", qos: .utility)

    /// Facts measured in the background and not yet applied, by path.
    private var pendingFacts: [String: ClipFacts] = [:]
    private var factsFlushScheduled = false

    /// Fills every entry it already knows the length of, and sends the rest to be
    /// measured. Does not notify: its callers do, once.
    private func fillDurations() {
        var toMeasure: [URL] = []
        for index in items.indices where items[index].duration == nil || items[index].frameCount == nil {
            guard let url = items[index].url, let path = pathKey(items[index]) else { continue }
            if let seconds = measuredDurations[path], items[index].duration == nil {
                items[index].duration = seconds
            }
            if askedPaths.insert(path).inserted {
                toMeasure.append(url)
            }
        }
        guard !toMeasure.isEmpty else { return }
        durationQueue.async { [weak self] in
            for url in toMeasure {
                let facts = ClipProbe.facts(of: url)
                self?.deliver(facts, for: url)
            }
        }
    }

    /// Hands one measurement to the main thread — collected, and applied in BATCHES:
    /// one rebuild per batch, not one per clip. Per clip, importing 500 clips rebuilt
    /// all three libraries 500 times (audit 09-26 R3).
    ///
    /// Called on the measuring queue. Through the run loop rather than the main queue:
    /// the self-QA drives the app from a nested `RunLoop.run`, which never drains a
    /// main-queue block.
    func deliver(_ facts: ClipFacts?, for url: URL) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let path = url.standardizedFileURL.path
            if let facts {
                self.pendingFacts[path] = facts
            } else {
                Log.warn(.app, "no duration for \(url.lastPathComponent); the list shows —")
            }
            guard !self.factsFlushScheduled else { return }
            self.factsFlushScheduled = true
            // A timer in common modes, not `asyncAfter`: the self-QA's nested run loop
            // does not drain the main queue, and a timer fires in both.
            RunLoop.main.add(Timer(timeInterval: Self.factsBatchInterval, repeats: false) { [weak self] _ in
                self?.flushFacts()
            }, forMode: .common)
        }
        CFRunLoopWakeUp(main)
    }

    /// How often measured facts are applied: at most four rebuilds a second.
    static let factsBatchInterval: TimeInterval = 0.25

    /// Applies every pending measurement, with one notification.
    private func flushFacts() {
        guard factsFlushScheduled else { return }
        factsFlushScheduled = false
        let batch = pendingFacts
        pendingFacts = [:]
        guard !batch.isEmpty else { return }
        applyFacts(byPath: batch)
    }

    /// Sets measured facts on every entry for those files (the same file may be in
    /// two bins), stores them, and notifies once.
    func applyFacts(byPath facts: [String: ClipFacts]) {
        var changed: [String] = []
        for index in items.indices {
            guard let path = pathKey(items[index]), let fact = facts[path] else { continue }
            items[index].duration = fact.duration
            items[index].frameCount = fact.frameCount
            items[index].frameRate = fact.frameRate
            changed.append(items[index].id)
        }
        for (path, fact) in facts {
            measuredDurations[path] = fact.duration
            askedPaths.insert(path)
        }
        guard !changed.isEmpty else { return }
        persist(changed)
        notify()
    }

    // MARK: - Optimized media (0.4.10)

    /// Links an optimized file to a clip (and the catalog), or clears the link.
    func setOptimized(path: String?, canvas: String?, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].optimizedPath = path
        items[index].optimizedCanvas = canvas
        persist([id])
        notify()
    }

    /// The file to PLAY for a clip at `url`: its optimized file when there is one for
    /// this canvas and it exists, otherwise the original. Never black: a missing
    /// optimized file falls back.
    func playbackURL(for url: URL, canvas: String) -> (url: URL, optimized: Bool) {
        let standard = url.standardizedFileURL.path
        guard let item = items.first(where: { pathKey($0) == standard }),
              let path = item.optimizedPath, item.optimizedCanvas == canvas else { return (url, false) }
        guard FileManager.default.fileExists(atPath: path) else {
            Log.warn(.app, "optimized file for \(url.lastPathComponent) is missing; playing the original")
            return (url, false)
        }
        return (URL(fileURLWithPath: path), true)
    }

    // MARK: - Marks

    func marks(for id: String) -> (inPoint: Double?, outPoint: Double?) {
        marks[id] ?? (nil, nil)
    }

    /// Records marks WITHOUT notifying: they are drawn by the thumbnail that set them,
    /// and rebuilding three libraries on every I and O would be a hitch per keypress.
    func setMarks(inPoint: Double?, outPoint: Double?, for id: String) {
        marks[id] = (inPoint == nil && outPoint == nil) ? nil : (inPoint, outPoint)
        persist([id])
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

    /// Every bin, filled or not, as paths (BinPath): a bin inside another is
    /// "Outer/Inner". The bins above a filled or empty bin exist too, even with no
    /// clips of their own — a folder of folders is still a folder.
    var binNames: [String] {
        var all = Set(items.compactMap(\.bin)).union(emptyBins)
        for path in all { all.formUnion(BinPath.ancestors(of: path)) }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The bins directly inside `parent` (the top level when nil), as paths.
    func childBins(of parent: String?) -> [String] {
        binNames.filter { BinPath.parent(of: $0) == parent }
    }

    /// How many clips a bin holds, counting the bins inside it — what its tile says.
    ///
    /// From a table built in ONE pass and kept until the library changes. Every folder
    /// tile asks this as it is laid out; scanning every clip for each tile, on every
    /// relayout, was ~16% of the main thread during a 1,000-clip import — bin names come
    /// from the file system decomposed, so each comparison took Swift's slow
    /// normalising path (sampled, 0.4.7).
    func count(inBin bin: String) -> Int {
        if binCounts == nil {
            var counts: [String: Int] = [:]
            for item in items {
                guard let path = item.bin else { continue }
                counts[path, default: 0] += 1
                for ancestor in BinPath.ancestors(of: path) { counts[ancestor, default: 0] += 1 }
            }
            binCounts = counts
        }
        return binCounts?[bin] ?? 0
    }

    /// Entries per bin; nil when the library has changed since it was counted.
    private var binCounts: [String: Int]?

    /// An unused bin path inside `parent`: "untitled bin", then "untitled bin 2" —
    /// the Finder's pattern, unique among its neighbours.
    func nextBinName(base: String = "untitled bin", in parent: String? = nil) -> String {
        let existing = Set(childBins(of: parent).map { BinPath.leaf(of: $0).lowercased() })
        guard existing.contains(base.lowercased()) else { return BinPath.join(parent, base) }
        var number = 2
        while existing.contains("\(base) \(number)".lowercased()) { number += 1 }
        return BinPath.join(parent, "\(base) \(number)")
    }

    /// Makes an empty bin inside `parent` with an unused name and returns its path.
    @discardableResult
    func addBin(in parent: String? = nil) -> String {
        let name = nextBinName(in: parent)
        emptyBins.insert(name)
        persistEmptyBins()
        notify()
        return name
    }

    /// Renames a bin — its own name, where it is — and returns its new path. The
    /// clips and the bins inside it go with it.
    ///
    /// The items carry the bin PATH rather than an identifier, so a rename has to move
    /// them too — otherwise the old bin keeps its contents and the renamed one is
    /// empty, which looks exactly like the rename having failed. Renaming onto an
    /// existing bin merges the two, as dropping a folder of the same name already does.
    @discardableResult
    func renameBin(from oldPath: String, to newName: String) -> String {
        let leaf = BinPath.sanitisedLeaf(newName)
        let newPath = BinPath.join(BinPath.parent(of: oldPath), leaf)
        guard !leaf.isEmpty, newPath != oldPath else { return oldPath }
        rebase(oldPath, onto: newPath)
        return newPath
    }

    /// Deletes a bin. Its clips and the bins inside it move up into its parent rather
    /// than out of the library: a bin is a way of arranging clips, and throwing one
    /// away should not throw away what was arranged in it.
    func deleteBin(_ path: String) {
        rebase(path, onto: BinPath.parent(of: path))
    }

    /// Moves everything within `oldPath` to the same place within `newPath` (nil =
    /// the top level): clips, and the empty bins that keep the shape.
    private func rebase(_ oldPath: String, onto newPath: String?) {
        var moved: [String] = []
        for index in items.indices {
            guard let bin = items[index].bin, BinPath.isWithin(bin, oldPath) else { continue }
            items[index].bin = BinPath.replacingPrefix(of: bin, oldPath, with: newPath)
            moved.append(items[index].id)
        }
        var rebuilt: Set<String> = []
        for bin in emptyBins {
            if BinPath.isWithin(bin, oldPath) {
                if let moved = BinPath.replacingPrefix(of: bin, oldPath, with: newPath) { rebuilt.insert(moved) }
            } else {
                rebuilt.insert(bin)
            }
        }
        emptyBins = rebuilt
        persist(moved)
        persistEmptyBins()
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
