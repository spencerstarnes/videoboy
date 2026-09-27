//
//  ImportModeView.swift — Import mode, the Lightroom-model import window (proposal §5).
//
//  Purpose : Sources on the left, the media grid in the centre (with a viewer above it),
//            Add / Move / Copy on the right. Pick a source, tick clips, Import.
//  Inputs  : the preference store (destination, favorites), the library (for DUP and
//            bin names), and an import action handed in by the owner.
//  Outputs : an import request — URLs, method, destination, bin — which the owner runs
//            as the usual background `ImportJob` into the library and catalog.
//  Connects: ModeController (shows it), ImportSources (sidebar), HoverScrubView (the
//            library tile's hover-scrub, reused), LocationRow (destination),
//            ShellController.importFiles(_:method:destination:bin:).
//  Extend  : Copy + Optimize (0.4.10) enables `optimizeCheck` and its preset for Copy.
//
//  THREADING. Listing a source, stat-ing files, DUP detection and probing picture shape
//  run on `listQueue`. Results come back through the main RUN LOOP (not the main queue:
//  the self-QA drives the app from a nested `RunLoop.run`, which does not drain it),
//  tagged with a generation so a slow listing of a previous source is dropped.
//  The viewer is an `AVPlayerView` with its own `AVPlayer`: auditioning never touches
//  the engine's channels.
//

import AppKit
import AVFoundation
import AVKit
import VideoboyCore

/// One file in the grid.
struct ImportEntry {
    let url: URL
    let size: Int
    let isDuplicate: Bool
    /// "DV" / "MPEG" for clips the bitstream effects work on; nil otherwise.
    let wedge: String?
    /// "⚠16:9", "⚠vertical" — a shape that is not the 4:3 canvas; nil when it fits.
    let mismatch: String?
    var isChecked: Bool
}

/// Import mode's view.
final class ImportModeView: NSView {

    private let store: PreferenceStore
    private let library: LibraryModel
    /// Runs the import. Set by the owner.
    var onImport: ((_ urls: [URL], _ method: ImportMethod, _ destination: URL?, _ bin: String?) -> Void)?

    private let listQueue = DispatchQueue(label: "videoboy.import-mode", qos: .userInitiated)
    private var generation = 0

    // Sidebar
    private let sourcesTable = NSTableView()
    private var rows: [(header: String?, source: ImportSource?)] = []
    private(set) var currentSource: ImportSource?

    // Grid
    private let filter = Controls.segmented(["All", "New", "In library"], selected: 0)
    private let includeSubfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 150, minValue: 100, maxValue: 260, target: nil, action: nil)
    private let collection = NSCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let gridStatus = Controls.label("Choose a source on the left.", color: Theme.Color.textTertiary)
    private(set) var entries: [ImportEntry] = []
    private var shown: [Int] = []  // indices into `entries` after the filter

    // Viewer
    let playerView = AVPlayerView()
    private var viewerHeight: NSLayoutConstraint?
    private let viewerToggle = NSButton(title: "Hide Viewer", target: nil, action: nil)

    // Right pane
    let methodControl = Controls.segmented(["ADD", "MOVE", "COPY"], selected: 0)
    private(set) var destinationRow: LocationRow!
    private var destination: URL
    let subfolderCheck = NSButton(checkboxWithTitle: "Into subfolder", target: nil, action: nil)
    private let subfolderField = NSTextField(string: "")
    let binPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let skipDuplicates = NSButton(checkboxWithTitle: "Skip duplicates", target: nil, action: nil)
    let optimizeCheck = NSButton(checkboxWithTitle: "Optimize while copying — coming in 0.4.10",
                                 target: nil, action: nil)
    let optimizePreset = Controls.popUp(SetupChoices.optimizePresets, enabled: false)
    let importButton = NSButton(title: "Import", target: nil, action: nil)

    init(store: PreferenceStore, library: LibraryModel) {
        self.store = store
        self.library = library
        self.destination = store.preferences.mediaLocation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.content.cgColor
        setAccessibilityIdentifier("import-mode")
        build()
        library.observe { [weak self] in self?.libraryChanged() }
        reloadSources()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    // MARK: - Layout

    private func build() {
        let sidebar = buildSidebar()
        let centre = buildCentre()
        let right = buildRightPane()
        for view in [sidebar, centre, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            right.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            right.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.widthAnchor.constraint(equalToConstant: 300),
            centre.topAnchor.constraint(equalTo: topAnchor),
            centre.bottomAnchor.constraint(equalTo: bottomAnchor),
            centre.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 10),
            centre.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -14)
        ])
        applyMethodRules()
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: .init("source"))
        sourcesTable.addTableColumn(column)
        sourcesTable.headerView = nil
        sourcesTable.style = .sourceList
        sourcesTable.rowHeight = 24
        sourcesTable.dataSource = self
        sourcesTable.delegate = self
        sourcesTable.setAccessibilityIdentifier("import-sources")
        let scroll = NSScrollView()
        scroll.documentView = sourcesTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let add = Controls.button("+", target: self, action: #selector(addFavorite))
        add.toolTip = "Add a folder to Favorites"
        let remove = Controls.button("−", target: self, action: #selector(removeFavorite))
        remove.toolTip = "Remove the selected favorite"
        let eject = Controls.button("⏏", target: self, action: #selector(ejectSelected))
        eject.toolTip = "Eject the selected device"
        let buttons = Controls.row([add, remove, eject, Controls.spacer()], spacing: 4)

        let stack = Controls.column([scroll, buttons], spacing: 6)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        stack.wantsLayer = true
        stack.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 8, right: 6)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    private func buildCentre() -> NSView {
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect   // letterboxed, never deformed
        playerView.setAccessibilityIdentifier("import-viewer")
        playerView.translatesAutoresizingMaskIntoConstraints = false
        let height = playerView.heightAnchor.constraint(equalToConstant: 260)
        height.isActive = true
        viewerHeight = height
        viewerToggle.bezelStyle = .rounded
        viewerToggle.target = self
        viewerToggle.action = #selector(toggleViewer)

        filter.target = self
        filter.action = #selector(filterChanged)
        let all = Controls.button("All", target: self, action: #selector(checkAll))
        let none = Controls.button("None", target: self, action: #selector(checkNone))
        includeSubfolders.target = self
        includeSubfolders.action = #selector(subfoldersChanged)
        includeSubfolders.state = .on
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let bar = Controls.row([filter, all, none, includeSubfolders, Controls.spacer(),
                                Controls.label("Size", color: Theme.Color.textTertiary), sizeSlider,
                                viewerToggle], spacing: 10)

        layout.itemSize = NSSize(width: 150, height: 130)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.backgroundColors = [.clear]
        collection.register(ImportTileItem.self, forItemWithIdentifier: ImportTileItem.identifier)
        collection.setAccessibilityIdentifier("import-grid")
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = Controls.column([playerView, bar, gridStatus, scroll], spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        for view in [playerView, bar, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func buildRightPane() -> NSView {
        methodControl.target = self
        methodControl.action = #selector(methodChanged)
        methodControl.setAccessibilityIdentifier("import-method")
        destinationRow = LocationRow(
            caption: "Destination", current: destination,
            prompt: "Where should moved or copied clips go?"
        ) { [weak self] url in self?.destination = url }
        subfolderCheck.target = self
        subfolderCheck.action = #selector(methodChanged)
        subfolderField.placeholderString = "Subfolder name"
        binPopUp.target = self
        binPopUp.action = #selector(binChanged)
        skipDuplicates.state = .on
        optimizeCheck.isEnabled = false
        optimizeCheck.toolTip = "Copy + Optimize arrives in 0.4.10"
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.setAccessibilityIdentifier("import-go")
        refreshBins()

        func heading(_ text: String) -> NSTextField {
            Controls.label(text, font: Theme.Font.panelTitle, color: Theme.Color.textPrimary)
        }
        return Controls.column([
            methodControl,
            Controls.note("Add catalogs clips where they are. Move puts them in the destination. "
                + "Copy copies them there and leaves the originals.", width: 290),
            heading("Destination"), destinationRow,
            Controls.row([subfolderCheck, subfolderField], spacing: 6),
            heading("Optimize media"), optimizeCheck,
            Controls.row([Controls.label("Preset", color: Theme.Color.textSecondary), optimizePreset], spacing: 6),
            heading("Library"),
            Controls.row([Controls.label("Into bin", color: Theme.Color.textSecondary), binPopUp], spacing: 6),
            skipDuplicates,
            Controls.row([Controls.spacer(), importButton], spacing: 6)
        ], spacing: 10)
    }

    // MARK: - Greying (proposal §5: greyed, never hidden)

    var method: ImportMethod {
        [ImportMethod.add, .move, .copy][max(methodControl.selectedSegment, 0)]
    }

    /// Destination and Optimize follow the method; Move follows the source.
    private func applyMethodRules() {
        let allowsMove = currentSource?.allowsMove ?? true
        methodControl.setEnabled(allowsMove, forSegment: 1)
        if !allowsMove, methodControl.selectedSegment == 1 { methodControl.selectedSegment = 2 }
        let usesDestination = method.usesDestination
        destinationRow.chooseButton.isEnabled = usesDestination
        destinationRow.pathLabel.textColor = usesDestination ? Theme.Color.textSecondary : Theme.Color.textTertiary
        subfolderCheck.isEnabled = usesDestination
        subfolderField.isEnabled = usesDestination && subfolderCheck.state == .on
        // Copy + Optimize is 0.4.10: disabled in every method until then.
        optimizeCheck.isEnabled = false
        optimizePreset.isEnabled = false
        updateImportButton()
    }

    private func updateImportButton() {
        let count = importableURLs().count
        importButton.title = count == 1 ? "Import 1" : "Import \(count)"
        importButton.isEnabled = count > 0
    }

    /// Points Move/Copy somewhere else — for self-QA (scratch folders only).
    func setDestinationForChecks(_ url: URL) {
        destination = url
        destinationRow.pathLabel.stringValue = url.path
    }

    /// Whether the destination controls are live — for self-QA.
    var destinationEnabled: Bool { destinationRow.chooseButton.isEnabled }
    var moveEnabled: Bool { methodControl.isEnabled(forSegment: 1) }

    // MARK: - Sources

    /// Lists volumes, favorites and locations off the main thread.
    func reloadSources() {
        let favorites = store.preferences.importFavorites
        listQueue.async { [weak self] in
            let sections = ImportSources.discover(favorites: favorites)
            Self.onMain {
                guard let self else { return }
                self.rows = sections.flatMap { section, sources in
                    [(header: section.rawValue, source: nil)] + sources.map { (header: nil, source: $0) }
                }
                self.sourcesTable.reloadData()
            }
        }
    }

    /// Shows a source's clips. Returns at once; the grid fills when the listing arrives.
    func show(_ source: ImportSource) {
        currentSource = source
        applyMethodRules()
        generation += 1
        let wanted = generation
        let deep = includeSubfolders.state == .on
        let libraryPaths = library.filePaths()
        gridStatus.stringValue = "Reading \(source.title)…"
        entries = []
        applyFilter()
        listQueue.async { [weak self] in
            let listed = Self.list(source.url, deep: deep, libraryPaths: libraryPaths)
            Self.onMain {
                guard let self, self.generation == wanted else { return }
                self.entries = listed
                self.gridStatus.stringValue = listed.isEmpty
                    ? "No clips in \(source.title)."
                    : "\(listed.count) clips in \(source.title)"
                self.applyFilter()
            }
        }
    }

    /// Everything playable under `folder`, with its badges. Blocking I/O: `listQueue` only.
    private static func list(_ folder: URL, deep: Bool, libraryPaths: [String]) -> [ImportEntry] {
        let urls: [URL]
        if deep {
            urls = ImportScan.walk(folder).filter { !$0.isSequence }.map(\.url)
        } else {
            urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ImportScan.playableExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func size(_ url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let paths = Set(libraryPaths)
        let nameSizes = Set(libraryPaths.map { path -> String in
            let url = URL(fileURLWithPath: path)
            return "\(url.lastPathComponent.lowercased())|\(size(url))"
        })
        return urls.map { url in
            let bytes = size(url)
            let duplicate = paths.contains(url.standardizedFileURL.path)
                || nameSizes.contains("\(url.lastPathComponent.lowercased())|\(bytes)")
            let ext = url.pathExtension.lowercased()
            let wedge: String? = ext == "dv" ? "DV" : (ClipDecoders.mpegExtensions.contains(ext) ? "MPEG" : nil)
            return ImportEntry(url: url, size: bytes, isDuplicate: duplicate, wedge: wedge,
                               mismatch: wedge == nil ? shapeWarning(url) : nil, isChecked: !duplicate)
        }
    }

    /// "⚠16:9" / "⚠vertical" when a clip's upright shape is not 4:3. DV and MPEG are
    /// SD here and not probed.
    private static func shapeWarning(_ url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        let width = abs(size.width), height = abs(size.height)
        guard width > 0, height > 0 else { return nil }
        let aspect = width / height
        if aspect < 1 { return "⚠vertical" }
        if abs(aspect - 4.0 / 3.0) < 0.1 || abs(aspect - 3.0 / 2.0) < 0.05 { return nil }
        return aspect > 1.6 ? "⚠16:9" : "⚠shape"
    }

    /// Runs a block on the main run loop (see THREADING).
    private static func onMain(_ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }

    private var libraryRefresh: DispatchWorkItem?

    /// After an import the DUP badges are stale; re-list once things settle.
    private func libraryChanged() {
        refreshBins()
        libraryRefresh?.cancel()
        guard let source = currentSource else { return }
        let work = DispatchWorkItem { [weak self] in self?.show(source) }
        libraryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Grid

    private func applyFilter() {
        shown = entries.indices.filter { index in
            switch filter.selectedSegment {
            case 1: return !entries[index].isDuplicate
            case 2: return entries[index].isDuplicate
            default: return true
            }
        }
        collection.reloadData()
        updateImportButton()
    }

    fileprivate func toggle(_ shownIndex: Int, checked: Bool) {
        guard shown.indices.contains(shownIndex) else { return }
        entries[shown[shownIndex]].isChecked = checked
        updateImportButton()
    }

    /// Loads a clip into the viewer's own player.
    func openInViewer(_ url: URL) {
        let player = AVPlayer(url: url)
        player.isMuted = false
        playerView.player?.pause()
        playerView.player = player
        player.play()
        if viewerHeight?.constant == 0 { toggleViewer() }
    }

    /// The clip in the viewer — for self-QA.
    var viewerURL: URL? { (playerView.player?.currentItem?.asset as? AVURLAsset)?.url }

    override func viewDidHide() {
        super.viewDidHide()
        playerView.player?.pause()   // leaving Import mode never leaves audio running
    }

    // MARK: - Import

    /// The ticked clips, minus duplicates when "Skip duplicates" is on.
    func importableURLs() -> [URL] {
        entries.filter { $0.isChecked && !(skipDuplicates.state == .on && $0.isDuplicate) }.map(\.url)
    }

    /// The destination this import would use (with the subfolder), or nil for Add.
    var resolvedDestination: URL? {
        guard method.usesDestination else { return nil }
        let name = subfolderField.stringValue.trimmingCharacters(in: .whitespaces)
        return subfolderCheck.state == .on && !name.isEmpty
            ? destination.appendingPathComponent(name, isDirectory: true) : destination
    }

    /// The bin chosen: the source folder's name, none, or an existing bin.
    private var chosenBin: String? {
        switch binPopUp.indexOfSelectedItem {
        case 0: return currentSource?.title
        case 1: return nil
        default: return binPopUp.titleOfSelectedItem
        }
    }

    @objc func importPressed() {
        let urls = importableURLs()
        guard !urls.isEmpty else { return }
        Log.info(.app, "import mode: \(method.rawValue) \(urls.count) clips"
            + (resolvedDestination.map { " to \($0.path)" } ?? ""))
        onImport?(urls, method, resolvedDestination, chosenBin)
    }

    private func refreshBins() {
        let selected = binPopUp.titleOfSelectedItem
        binPopUp.removeAllItems()
        binPopUp.addItems(withTitles: ["Source folder's name", "No bin"] + library.binNames)
        if let selected, binPopUp.item(withTitle: selected) != nil { binPopUp.selectItem(withTitle: selected) }
    }

    // MARK: - Actions

    @objc private func methodChanged() { applyMethodRules() }
    @objc private func binChanged() {}
    @objc private func filterChanged() { applyFilter() }
    @objc private func subfoldersChanged() { if let currentSource { show(currentSource) } }
    @objc private func sizeChanged() {
        let width = CGFloat(sizeSlider.doubleValue)
        layout.itemSize = NSSize(width: width, height: width * 0.62 + 36)
    }
    @objc private func checkAll() { setAllChecked(true) }
    @objc private func checkNone() { setAllChecked(false) }

    func setAllChecked(_ checked: Bool) {
        for index in shown { entries[index].isChecked = checked }
        collection.reloadData()
        updateImportButton()
    }

    @objc private func toggleViewer() {
        let collapsed = viewerHeight?.constant == 0
        viewerHeight?.constant = collapsed ? 260 : 0
        playerView.isHidden = !collapsed
        viewerToggle.title = collapsed ? "Hide Viewer" : "Show Viewer"
    }

    @objc private func addFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add to Favorites"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.preferences.importFavorites.append(url.path)
        reloadSources()
    }

    @objc private func removeFavorite() {
        guard let source = selectedSource, source.section == .favorites else { return }
        store.preferences.importFavorites.removeAll { $0 == source.url.path }
        reloadSources()
    }

    @objc private func ejectSelected() {
        guard let source = selectedSource, source.isEjectable else { return }
        let url = source.url
        listQueue.async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                Self.onMain { [weak self] in self?.reloadSources() }
            } catch {
                Log.warn(.app, "could not eject \(url.path): \(error)")
            }
        }
    }

    private var selectedSource: ImportSource? {
        let row = sourcesTable.selectedRow
        return rows.indices.contains(row) ? rows[row].source : nil
    }
}

// MARK: - Sidebar table

extension ImportModeView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].header != nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].source != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let header = rows[row].header {
            return Controls.label(header.uppercased(), font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
        }
        guard let source = rows[row].source else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: source.symbolName,
                                               accessibilityDescription: nil) ?? NSImage())
        let label = Controls.label(source.title, color: Theme.Color.textPrimary)
        cell.textField = label
        let row = Controls.row([image, label], spacing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let source = selectedSource { show(source) }
    }
}

// MARK: - Grid

extension ImportModeView: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shown.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ImportTileItem.identifier, for: indexPath)
        guard let tile = item as? ImportTileItem, shown.indices.contains(indexPath.item) else { return item }
        let index = indexPath.item
        tile.configure(entries[shown[index]])
        tile.onChecked = { [weak self] checked in self?.toggle(index, checked: checked) }
        tile.onOpen = { [weak self] url in self?.openInViewer(url) }
        return tile
    }
}

/// A tile: the library's hover-scrub picture, a checkbox, badges and the name.
final class ImportTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("import-tile")

    private let picture = HoverScrubView()
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let badges = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.displayWarning)
    private let name = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textSecondary)
    private var url: URL?
    var onChecked: ((Bool) -> Void)?
    var onOpen: ((URL) -> Void)?

    override func loadView() {
        let tile = ImportTileView()
        tile.onDoubleClick = { [weak self] in if let url = self?.url { self?.onOpen?(url) } }
        name.lineBreakMode = .byTruncatingMiddle
        check.target = self
        check.action = #selector(checkChanged)
        for view in [picture, check, badges, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: tile.topAnchor),
            picture.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            picture.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -4),
            check.topAnchor.constraint(equalTo: tile.topAnchor, constant: 4),
            check.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 4),
            badges.topAnchor.constraint(equalTo: tile.topAnchor, constant: 5),
            badges.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -5),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            name.heightAnchor.constraint(equalToConstant: 16)
        ])
        view = tile
    }

    func configure(_ entry: ImportEntry) {
        url = entry.url
        picture.item = ShellController.libraryItem(for: entry.url)
        check.state = entry.isChecked ? .on : .off
        badges.stringValue = [entry.isDuplicate ? "DUP" : nil, entry.wedge, entry.mismatch]
            .compactMap { $0 }.joined(separator: " ")
        name.stringValue = entry.url.lastPathComponent
        view.alphaValue = entry.isDuplicate ? 0.55 : 1   // duplicates greyed
    }

    /// The badge text — for self-QA.
    var badgeText: String { badges.stringValue }

    @objc private func checkChanged() { onChecked?(check.state == .on) }
}

/// The tile's view: a double-click opens the clip in the viewer. Single presses on the
/// picture arrive here too — `HoverScrubView` passes a press up when its superview is
/// not a library cell.
final class ImportTileView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
