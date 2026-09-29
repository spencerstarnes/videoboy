//
//  LibraryPanelBody.swift — the two sub-mix libraries and the central asset browser.
//
//  Purpose : SPEC 14.2's libraries. Each panel browses the one shared library in its
//            own icon, list or column view, and behaves like a Finder window while
//            doing it: bins are folders, a selection can be dragged, copied, pasted,
//            filed and removed, ⌘A selects everything showing, and right-clicking
//            anything offers what can be done to it.
//  Inputs  : the LibraryModel; the asset browser's fixed tabs (generators, sources).
//  Outputs : `onItemOpened` (load into a channel), `onItemQueued`, `onFilesDropped`.
//  Connects: LibraryBrowser (what this panel is looking at), LibraryGridView,
//            LibraryListView, LibraryColumnView (the three ways of drawing it),
//            ShellController (loads, queues and imports).
//  Extend  : a new thing you can do to a selection is one menu item in
//            `libraryMenu` and, if it has a key, one Edit-menu action here. The views
//            only ever report WHERE; what it means is decided in this file.
//

import AppKit
import VideoboyCore

/// Where a clip goes when it is double-clicked, and which of the pair is next.
///
/// FCP's behaviour: choosing a destination once and then loading clip after clip
/// without re-choosing. The pair alternates so loading two clips fills both sides of
/// a crossfader, which is the thing you almost always want next.
final class ChannelDestination {

    /// The pair currently being filled.
    enum Pair: String, CaseIterable {
        case ab
        case cd

        var displayName: String {
            switch self {
            case .ab: "A/B"
            case .cd: "C/D"
            }
        }

        var channels: [String] {
            switch self {
            case .ab: ["A", "B"]
            case .cd: ["C", "D"]
            }
        }
    }

    var pair: Pair = .ab {
        // Switching pair starts at that pair's first channel rather than carrying the
        // old index across, so choosing C/D loads C next and not D.
        didSet { index = 0 }
    }
    private var index = 0

    /// Every channel, in the order the focus control lists them.
    static let allChannels = ["A", "B", "C", "D"]

    /// Points the focus straight at one channel.
    func focus(channel: String) {
        guard let pairForChannel = Pair.allCases.first(where: { $0.channels.contains(channel) }),
              let position = pairForChannel.channels.firstIndex(of: channel) else { return }
        pair = pairForChannel   // resets index to 0 via didSet
        index = position
    }

    /// The channel the next double-click loads, then advances past.
    func takeNextChannel() -> String {
        let channels = pair.channels
        let channel = channels[index % channels.count]
        index = (index + 1) % channels.count
        return channel
    }

    /// The channel the next double-click WOULD load, without advancing.
    var nextChannel: String { pair.channels[index % pair.channels.count] }
}

/// Which kind of asset a browser tab shows.
enum AssetTab: String, CaseIterable {
    case sources
    case generators
    case graphics
    case clips
    case images
    /// Emulated machines — see EmuBrowserView.
    case emu

    var displayName: String {
        switch self {
        case .sources: "Sources"
        case .generators: "Generators"
        case .graphics: "Graphics"
        case .clips: "Clips"
        case .images: "Images"
        case .emu: "EMU"
        }
    }

    /// What to say when a tab has nothing in it, so an empty grid is never just a
    /// blank rectangle the user has to guess about.
    var emptyMessage: String {
        switch self {
        case .sources: "No sources configured. Add one in Settings > Sources."
        case .generators: "No generators available."
        case .graphics: "SVG and vector sources are not built yet (SPEC §17)."
        case .clips: "No clips yet. Drop clips or folders here, or paste them."
        case .images: "Still-image sources are not built yet."
        case .emu: "No emulated machines are set up."
        }
    }
}

/// A library panel: a toolbar, and the library drawn in one of three views.
final class LibraryPanelBody: NSView {

    /// The ONE library. All three panels share it, so a folder dropped on the left
    /// appears on the right and a bin made in one exists in the other.
    private let model: LibraryModel

    /// What this panel is looking at: search, sort, open bin, selection.
    let browser: LibraryBrowser

    /// The Sources tab's contents — every `ConfiguredSource` from Settings, as tiles.
    ///
    /// Deliberately NOT in `LibraryModel`: there is one list of them for the whole app,
    /// they are not clips, and they should never show up in a clip search. Set by
    /// `ShellController` whenever the configured list changes.
    var configuredSourceItems: [LibraryItem] = [] {
        didSet { if currentTab == .sources { showTab(currentTab) } }
    }

    /// The ISF generators, shown in the Generators tab after the built-in ones.
    var isfGeneratorItems: [LibraryItem] = [] {
        didSet { if currentTab == .generators { showTab(currentTab) } }
    }

    /// How THIS panel draws the library. Per panel: the two sub-mix browsers are used
    /// at the same time to find two different clips, so one being a list while the
    /// other is icons is the normal case.
    private(set) var viewStyle: LibraryViewStyle = .icon
    private var viewStyleToggle: VBSlideToggle?

    /// The three views. The grid always exists; the others are built the first time
    /// they are asked for — most sessions never leave the icons.
    let gridView: LibraryGridView
    private(set) var listView: LibraryListView?
    private(set) var columnView: LibraryColumnView?

    /// "‹ Library › Reel A", above the icon and list views while a bin is open.
    let pathBar: LibraryPathBar
    private var pathBarHeight: NSLayoutConstraint?

    /// Where the views go. Everything below the toolbar.
    private let viewArea = NSView()
    private let emptyLabel = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)

    private(set) var currentTab: AssetTab = .clips
    /// The bin open on the Clips tab, kept while another tab is showing.
    private var clipsOpenBin: String?

    /// Called when an item is double-clicked: the clip, its channel, and any marks.
    var onItemOpened: ((LibraryItem, String, ClosedRange<Double>?) -> Void)?

    /// Where double-clicked clips go, and which of the pair is next.
    let destination = ChannelDestination()

    /// Called when files are dropped or pasted into this library: the files, and the
    /// bin they should land in (nil for the top level).
    var onFilesDropped: (([URL], String?) -> Void)?

    /// The EMU tab's contents, supplied at construction.
    private let emuView: NSView?

    /// Highlighted while a drop is hovering over the toolbar.
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            layer?.borderWidth = isDropTarget ? 2 : 0
            layer?.borderColor = Theme.Color.accent.cgColor
            layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        }
    }

    /// The focus control, so its title can show which channel is next.
    private var destinationControl: NSSegmentedControl?
    /// The asset browser's tab strip.
    private var tabControl: NSSegmentedControl?

    /// Which channels this library keeps playlists for. Empty in the asset browser.
    private let playlistChannels: [String]

    /// The AUTO key, so every library can be kept showing the same state.
    private var autoPlayKey: VBOptionButton?

    /// Called when AUTO is toggled.
    var onAutoPlayChanged: ((Bool) -> Void)?

    /// Which channels the focus control offers. A bus library offers its own pair;
    /// the asset browser, which belongs to no bus, offers all four.
    private var focusChannels: [String] {
        playlistChannels.isEmpty ? ChannelDestination.allChannels : playlistChannels
    }

    /// The Library / A / B tab strip, when this library has playlists.
    private var playlistTabs: NSSegmentedControl?

    /// Which view is showing: nil means the library, a letter means that channel's queue.
    private var shownPlaylist: String?

    /// The queue views, one per channel, in one scroll view.
    private var playlistViews: [String: PlaylistView] = [:]
    private let queueScroll = NSScrollView()

    /// Called when a clip is queued: (item, channel, playNext).
    var onItemQueued: ((LibraryItem, String, Bool) -> Void)?

    /// Called when a queued item is removed from a channel's playlist.
    var onQueuedItemRemoved: ((String, PlaylistItem.ID) -> Void)?

    /// Called when a channel's queue REPEAT key is toggled: (channel, repeats).
    var onQueueRepeatChanged: ((String, Bool) -> Void)?

    /// Where Copy writes and Paste reads. The self-QA points this at a private board
    /// so a check never overwrites what the person at the machine had copied.
    static var pasteboardForChecks: NSPasteboard?
    private var pasteboard: NSPasteboard { Self.pasteboardForChecks ?? .general }

    /// - Parameters:
    ///   - columns: unused since the grid became a collection view that fits its own
    ///     columns to the panel; kept so the call sites read as they did.
    ///   - showsTabs: true for the asset browser, which is tabbed by asset kind.
    init(
        model: LibraryModel, columns: Int, showsTabs: Bool,
        playlistChannels: [String] = [], emuView: NSView? = nil
    ) {
        self.model = model
        self.browser = LibraryBrowser(model: model)
        self.playlistChannels = playlistChannels
        self.emuView = emuView
        self.gridView = LibraryGridView(browser: browser)
        self.pathBar = LibraryPathBar()
        super.init(frame: .zero)
        wantsLayer = true
        _ = columns

        // A library is where you COLLECT things, so it accepts them being put there
        // anywhere on the panel — the toolbar included.
        registerForDraggedTypes(LibraryBrowser.droppedTypes)

        let headerRow = makeHeader(showsTabs: showsTabs)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)

        viewArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(viewArea)

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onUp = { [weak self] in self?.libraryGoUp() }
        pathBar.dropHandler = self
        pathBar.isHidden = true
        viewArea.addSubview(pathBar)
        let pathHeight = pathBar.heightAnchor.constraint(equalToConstant: 0)
        pathBarHeight = pathHeight

        gridView.actions = self
        viewArea.addSubview(gridView)
        pin(gridView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        viewArea.addSubview(emptyLabel)

        if let emuView {
            emuView.translatesAutoresizingMaskIntoConstraints = false
            emuView.isHidden = true
            viewArea.addSubview(emuView)
            NSLayoutConstraint.activate([
                emuView.topAnchor.constraint(equalTo: viewArea.topAnchor),
                emuView.leadingAnchor.constraint(equalTo: viewArea.leadingAnchor),
                emuView.trailingAnchor.constraint(equalTo: viewArea.trailingAnchor)
            ])
        }

        // One queue view per channel, in a scroll view of their own, hidden until
        // their tab is picked.
        let queueDocument = LibraryQueueDropView()
        queueDocument.translatesAutoresizingMaskIntoConstraints = false
        queueDocument.panel = self
        queueScroll.documentView = queueDocument
        queueScroll.hasVerticalScroller = true
        queueScroll.autohidesScrollers = true
        queueScroll.drawsBackground = false
        queueScroll.isHidden = true
        viewArea.addSubview(queueScroll)
        pin(queueScroll, belowPathBar: false)
        NSLayoutConstraint.activate([
            queueDocument.topAnchor.constraint(equalTo: queueScroll.contentView.topAnchor),
            queueDocument.leadingAnchor.constraint(equalTo: queueScroll.contentView.leadingAnchor),
            queueDocument.widthAnchor.constraint(equalTo: queueScroll.contentView.widthAnchor),
            queueDocument.heightAnchor.constraint(greaterThanOrEqualTo: queueScroll.contentView.heightAnchor)
        ])
        for channel in playlistChannels {
            let queue = PlaylistView(channel: channel)
            queue.translatesAutoresizingMaskIntoConstraints = false
            queue.isHidden = true
            queue.onRemove = { [weak self] id in
                self?.onQueuedItemRemoved?(channel, id)
            }
            queue.onRepeatChanged = { [weak self] repeats in
                self?.onQueueRepeatChanged?(channel, repeats)
            }
            queueDocument.addSubview(queue)
            playlistViews[channel] = queue
            NSLayoutConstraint.activate([
                queue.topAnchor.constraint(equalTo: queueDocument.topAnchor),
                queue.leadingAnchor.constraint(equalTo: queueDocument.leadingAnchor),
                queue.trailingAnchor.constraint(equalTo: queueDocument.trailingAnchor),
                queue.bottomAnchor.constraint(lessThanOrEqualTo: queueDocument.bottomAnchor)
            ])
        }

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            viewArea.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            viewArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            viewArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            viewArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),

            pathBar.topAnchor.constraint(equalTo: viewArea.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: viewArea.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: viewArea.trailingAnchor),
            pathHeight,

            emptyLabel.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 4),
            emptyLabel.leadingAnchor.constraint(equalTo: viewArea.leadingAnchor, constant: 4),
            emptyLabel.trailingAnchor.constraint(equalTo: viewArea.trailingAnchor, constant: -4)
        ])

        // Every panel follows the library, so the three views of it cannot drift apart.
        model.observe { [weak self] in self?.scheduleReload() }

        showTab(currentTab)
        updateDestinationTitles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Fills the view area below the path bar with a view.
    private func pin(_ view: NSView, belowPathBar: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            belowPathBar
                ? view.topAnchor.constraint(equalTo: pathBar.bottomAnchor)
                : view.topAnchor.constraint(equalTo: viewArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: viewArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: viewArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: viewArea.bottomAnchor)
        ])
    }

    // MARK: - Header

    /// The toolbar. Unchanged in arrangement: a performer's hands know where these are.
    private func makeHeader(showsTabs: Bool) -> NSView {
        // The tabbed browser carries six tabs, a focus control, a search field and
        // Import. That does not fit one row at this panel's width, so the browser
        // gets two rows: what you are looking at on top, what you can do beneath.
        var topRow: [NSView] = []
        var bottomRow: [NSView] = []

        if showsTabs {
            // Selected on the tab actually showing. It was hard-wired to the first
            // segment, so the strip said "Sources" over a grid of clips.
            let tabs = Controls.segmented(
                AssetTab.allCases.map(\.displayName),
                selected: AssetTab.allCases.firstIndex(of: currentTab) ?? 0,
                target: self, action: #selector(tabChanged(_:)))
            tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
            tabControl = tabs
            topRow.append(tabs)
            topRow.append(Controls.spacer())
        } else if !playlistChannels.isEmpty {
            let titles = ["Library"] + playlistChannels
            let tabs = Controls.segmented(
                titles, selected: 0, target: self, action: #selector(playlistTabChanged(_:)))
            tabs.toolTip = "The library, or a source's up-next queue"
            tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
            playlistTabs = tabs
            bottomRow.append(tabs)
        } else {
            bottomRow.append(Controls.popUp(["Page 1"], enabled: false))
        }

        // Where a double-clicked clip goes: only this library's OWN pair, or all four
        // in the asset browser, which belongs to no bus.
        let destinationToggle = Controls.segmented(
            focusChannels, selected: 0,
            target: self, action: #selector(destinationChanged(_:)))
        destinationToggle.toolTip = "Focus — where the next clip you open lands"
        destinationToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        destinationControl = destinationToggle
        bottomRow.append(destinationToggle)

        // A bin button. Bins can also be made from the right-click menu or by dropping
        // a folder, but a visible control is what tells you the feature exists.
        let newBinButton = Controls.glyphButton(
            "＋", tooltip: "New bin", target: self, action: #selector(newBinPressed))
        topRow.append(newBinButton)

        // AUTO — does a clip start playing when it lands in a channel.
        let autoPlayKey = VBOptionButton(title: "AUTO")
        autoPlayKey.isOn = true
        autoPlayKey.target = self
        autoPlayKey.action = #selector(autoPlayToggled)
        autoPlayKey.toolTip = "Play a clip as soon as it is loaded into a channel"
        autoPlayKey.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.autoPlayKey = autoPlayKey
        bottomRow.append(autoPlayKey)

        // Icon, list, column — the three the Finder gives you.
        let styleImages: [NSImage] = LibraryViewStyle.allCases.compactMap {
            guard let image = NSImage(
                systemSymbolName: $0.symbolName, accessibilityDescription: $0.explanation)
            else { return nil }
            image.isTemplate = true
            return image
        }
        let styleToggle = VBSlideToggle(
            images: styleImages,
            tooltips: LibraryViewStyle.allCases.map(\.explanation),
            selected: LibraryViewStyle.allCases.firstIndex(of: viewStyle) ?? 0)
        styleToggle.target = self
        styleToggle.action = #selector(viewStyleChanged(_:))
        styleToggle.heightAnchor.constraint(equalToConstant: 18).isActive = true
        styleToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewStyleToggle = styleToggle
        bottomRow.append(styleToggle)

        let search = Controls.searchField(
            placeholder: showsTabs ? "Search library…" : "Search…", enabled: true)
        search.target = self
        search.action = #selector(searchChanged(_:))
        // The one thing in the row that can usefully give way.
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomRow.append(search)

        if showsTabs {
            let importButton = Controls.button("Import…", enabled: false)
            importButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            bottomRow.append(importButton)
        }

        // With no tab strip there is no top row to hang the bin button on, so it goes
        // at the end of the bottom one instead of vanishing.
        if topRow.count == 1, let onlyButton = topRow.first {
            topRow.removeAll()
            bottomRow.append(onlyButton)
        }

        if topRow.isEmpty {
            return Controls.row(bottomRow, spacing: 4)
        }
        return Controls.column([
            Controls.row(topRow, spacing: 4),
            Controls.row(bottomRow, spacing: 4)
        ], spacing: 3)
    }

    // MARK: - Showing

    /// Rebuilds on the NEXT runloop turn, coalescing repeated calls.
    ///
    /// The render loop runs on the main thread, so a rebuild is time the picture is not
    /// being drawn. A folder drop can change the library once per file; doing the work
    /// once at the end is the difference between one hitch and fifty. On the RUN LOOP
    /// rather than the main queue, because a dispatch block is not drained by the
    /// self-QA's nested `RunLoop.run`.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        // At most one rebuild per `minimumReloadInterval`. Each rebuild costs a layout
        // pass of ~25–35 ms when tiles change (in-process sampler, 1,000-clip import),
        // and an import changes the library every 80 ms while scanning: rebuilding on
        // every change stacked those passes against the display link and dropped a
        // refresh. An idle library still rebuilds on the next turn.
        // And the three library panels never rebuild in the same turn: one layout
        // pass building every new tile in all three grids at once was the last 30–45 ms
        // stretch. Each waits until `panelSpacing` after whichever panel went last.
        let now = CACurrentMediaTime()
        // Only while an import streams clips in: a search, a sort, one dropped clip
        // must show at once.
        var wait: CFTimeInterval = 0
        if Self.importsRunning > 0 {
            wait = max(0, Self.minimumReloadInterval - (now - lastReload))
            let nextSlot = Self.lastAnyReload + Self.panelSpacing - now
            if nextSlot > wait { wait = nextSlot }
        }
        Self.lastAnyReload = now + wait
        let run = { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.lastReload = CACurrentMediaTime()
            let start = Self.reloadCostsForChecks != nil ? CACurrentMediaTime() : 0
            self.reloadNow()
            if Self.reloadCostsForChecks != nil {
                Self.reloadCostsForChecks?.append((CACurrentMediaTime() - start) * 1000)
            }
        }
        if wait <= 0 {
            RunLoop.main.perform(inModes: [.common], block: run)
        } else {
            let timer = Timer(timeInterval: wait, repeats: false) { _ in run() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// See `scheduleReload`.
    static let minimumReloadInterval: CFTimeInterval = 0.35
    static let panelSpacing: CFTimeInterval = 0.1
    /// Imports in flight (set by ShellController): the throttle applies only then.
    static var importsRunning = 0
    private static var lastAnyReload: CFTimeInterval = 0
    private var lastReload: CFTimeInterval = 0

    /// Milliseconds each deferred rebuild took, across all three panels, while a
    /// check sets this non-nil.
    static var reloadCostsForChecks: [Double]?

    private var reloadScheduled = false

    /// Re-reads the library into whichever view is showing.
    func reloadNow() {
        browser.pruneSelection()
        if let open = browser.openBin, !model.binNames.contains(open) { browser.openBin = nil }
        let showingLibrary = shownPlaylist == nil && currentTab != .emu

        gridView.isHidden = !showingLibrary || viewStyle != .icon
        listView?.isHidden = !showingLibrary || viewStyle != .list
        columnView?.isHidden = !showingLibrary || viewStyle != .column
        queueScroll.isHidden = shownPlaylist == nil
        emuView?.isHidden = currentTab != .emu || shownPlaylist != nil

        let showsPath = showingLibrary && viewStyle != .column && browser.effectiveOpenBin != nil
        pathBar.isHidden = !showsPath
        pathBarHeight?.constant = showsPath ? LibraryPathBar.height : 0
        pathBar.setBin(browser.effectiveOpenBin)

        guard showingLibrary else {
            emptyLabel.isHidden = true
            return
        }
        switch viewStyle {
        case .icon: gridView.reload()
        case .list: listView?.reload()
        case .column: columnView?.reload()
        }

        let shown = viewStyle == .column ? browser.rootEntries() : browser.currentEntries()
        emptyLabel.isHidden = !shown.isEmpty
        if !browser.search.isEmpty {
            // An empty result while searching means "nothing matches", never "your
            // library is empty" — that text sent people looking for files still there.
            emptyLabel.stringValue = "Nothing in \(currentTab.displayName) matches “\(browser.search)”."
        } else if let open = browser.effectiveOpenBin, viewStyle != .column {
            emptyLabel.stringValue = "“\(open)” is empty. Drag clips here, or paste them, to file them."
        } else {
            emptyLabel.stringValue = currentTab.emptyMessage
        }
    }

    /// Points the browser at a tab's contents.
    private func showTab(_ tab: AssetTab) {
        if currentTab == .clips, tab != .clips { clipsOpenBin = browser.openBin }
        currentTab = tab
        browser.selection = []
        browser.anchor = nil
        switch tab {
        case .clips:
            browser.fixedItems = nil
            browser.openBin = clipsOpenBin
        case .sources:
            browser.fixedItems = configuredSourceItems
            browser.openBin = nil
        case .generators:
            browser.fixedItems = GeneratorKind.allCases.map { kind in
                var item = LibraryItem(
                    name: kind.displayName, badge: "GEN", isAvailable: true,
                    id: "generator:\(kind.rawValue)")
                item.generatorKind = kind
                item.thumbnail = GeneratorThumbnails.shared.image(for: kind)
                return item
            } + isfGeneratorItems
            browser.openBin = nil
        case .graphics, .images, .emu:
            browser.fixedItems = []
            browser.openBin = nil
        }
        reloadNow()
    }

    /// Builds the list or column view the first time it is wanted.
    private func ensureView(for style: LibraryViewStyle) {
        switch style {
        case .icon:
            break
        case .list where listView == nil:
            let list = LibraryListView(browser: browser)
            list.actions = self
            viewArea.addSubview(list, positioned: .below, relativeTo: emptyLabel)
            pin(list)
            listView = list
        case .column where columnView == nil:
            let columns = LibraryColumnView(browser: browser)
            columns.actions = self
            viewArea.addSubview(columns, positioned: .below, relativeTo: emptyLabel)
            pin(columns)
            columnView = columns
        default:
            break
        }
    }

    /// Switches the view style as the toggle would, for the self-QA.
    func setViewStyleForChecks(_ style: LibraryViewStyle) {
        guard let index = LibraryViewStyle.allCases.firstIndex(of: style),
              let toggle = viewStyleToggle else { return }
        toggle.selectedIndex = index
        viewStyleChanged(toggle)
    }

    /// The view in the current style that takes the keyboard.
    private var keyViewForStyle: NSView? {
        switch viewStyle {
        case .icon: gridView.collectionView
        case .list: listView?.outline
        case .column: columnView?.rootTable
        }
    }

    /// The view style key, so the self-QA can click it for real.
    var viewStyleToggleForChecks: VBSlideToggle? { viewStyleToggle }

    /// The view currently drawing the library, for the self-QA.
    var visibleLibraryView: NSView? {
        switch viewStyle {
        case .icon: gridView
        case .list: listView
        case .column: columnView
        }
    }

    // MARK: - Header actions

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard AssetTab.allCases.indices.contains(index) else { return }
        let tab = AssetTab.allCases[index]
        guard tab != currentTab else { return }
        showTab(tab)
        Log.info(.app, "asset browser showing \(tab.displayName)")
    }

    @objc private func viewStyleChanged(_ sender: VBSlideToggle) {
        let styles = LibraryViewStyle.allCases
        guard styles.indices.contains(sender.selectedIndex) else { return }
        viewStyle = styles[sender.selectedIndex]
        ensureView(for: viewStyle)
        reloadNow()
        // The keyboard follows the view. Left in the hidden one, ⌘A selected what the
        // OLD view had been showing, and the arrows moved a selection nobody could see.
        if let window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: viewArea), responder.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(keyViewForStyle)
        }
        Log.info(.app, "library view is now \(viewStyle.rawValue)")
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        browser.search = sender.stringValue.trimmingCharacters(in: .whitespaces)
        // Coalesced: once per keystroke would rebuild on every letter typed.
        scheduleReload()
    }

    @objc private func playlistTabChanged(_ sender: NSSegmentedControl) {
        // Segment 0 is the library; the rest are channels, in order.
        let index = sender.selectedSegment
        shownPlaylist = index <= 0 ? nil : playlistChannels[min(index - 1, playlistChannels.count - 1)]
        for (channel, view) in playlistViews { view.isHidden = channel != shownPlaylist }
        reloadNow()
    }

    /// Hands a channel's queue its current contents.
    func setPlaylist(_ playlist: Playlist, forChannel channel: String) {
        playlistViews[channel]?.setRepeats(playlist.repeats)
        playlistViews[channel]?.setItems(playlist.items)
        // The tab says how many are waiting, so the count is legible without
        // switching to it mid-set.
        guard let tabs = playlistTabs,
              let index = playlistChannels.firstIndex(of: channel) else { return }
        tabs.setLabel(
            playlist.isEmpty ? channel : "\(channel) \(playlist.count)", forSegment: index + 1)
    }

    /// The channel whose queue is showing, if one is — where a drop on the queue goes.
    var shownPlaylistChannel: String? { shownPlaylist }

    /// A channel's queue view — for self-QA.
    func playlistViewForChecks(_ channel: String) -> PlaylistView? { playlistViews[channel] }

    @objc private func newBinPressed() {
        makeBin(filing: [])
    }

    @objc private func autoPlayToggled() {
        onAutoPlayChanged?(autoPlayKey?.isOn ?? true)
    }

    /// Points the key at a state without firing its action.
    func setAutoPlay(_ isOn: Bool) {
        autoPlayKey?.isOn = isOn
    }

    @objc private func destinationChanged(_ sender: NSSegmentedControl) {
        let channels = focusChannels
        guard channels.indices.contains(sender.selectedSegment) else { return }
        destination.focus(channel: channels[sender.selectedSegment])
        updateDestinationTitles()
    }

    /// Marks which channel the next double-click will fill, with a caret and the focus
    /// colour — the same idea as the caret on an FX card's selector.
    private func updateDestinationTitles() {
        guard let control = destinationControl else { return }
        let focused = destination.nextChannel
        for (index, channel) in focusChannels.enumerated() {
            control.setLabel(
                channel == focused ? Theme.focusCaret + channel : channel, forSegment: index)
            if channel == focused { control.selectedSegment = index }
        }
        control.selectedSegmentBezelColor = Theme.Color.focusOn
        control.toolTip = "Focus — the next clip you open lands on \(focused), "
            + "then the focus moves to the other channel of that pair"
    }

    /// Sets which pair this library fills, for the sub-mix libraries that own a side.
    func setDestinationPair(_ pair: ChannelDestination.Pair) {
        destination.pair = pair
        updateDestinationTitles()
    }

    // MARK: - Library edits

    /// Adds items to the library.
    func addItems(_ newItems: [LibraryItem]) {
        guard !newItems.isEmpty else { return }
        let added = model.add(newItems)
        if !added.isEmpty { Log.info(.app, "added \(added.count) item(s) to the library") }
    }

    /// Moves an item into a bin, or out of one when `bin` is nil.
    func moveItem(named name: String, toBin bin: String?) {
        model.moveItem(named: name, toBin: bin)
        Log.info(.app, "moved \(name) to \(bin ?? "the top level")")
    }

    /// Every bin this library knows about, filled or not.
    var binNames: [String] { model.binNames }

    /// Makes a bin — empty, or holding the given clips — inside the bin being shown
    /// (the top level when none), selects it and puts its name into edit mode, as the
    /// Finder's New Folder does.
    private func makeBin(filing ids: [String]) {
        let parent = currentTab == .clips && shownPlaylist == nil ? browser.effectiveOpenBin : nil
        let name: String
        if ids.isEmpty {
            name = model.addBin(in: parent)
        } else {
            name = model.nextBinName(in: parent)
            model.moveItems(ids, toBin: name)
        }
        Log.info(.app, "created bin '\(name)'" + (ids.isEmpty ? "" : " holding \(ids.count) clip(s)"))
        // A bin lives in the clip library, so that is where it has to be seen being
        // made — in the bin it was made inside.
        if shownPlaylist != nil {
            playlistTabs?.selectedSegment = 0
            shownPlaylist = nil
            for view in playlistViews.values { view.isHidden = true }
        }
        if currentTab != .clips {
            tabControl?.selectedSegment = AssetTab.allCases.firstIndex(of: .clips) ?? 0
            showTab(.clips)
        }
        browser.openBin = parent
        browser.selection = [LibraryEntry.binPrefix + name]
        browser.anchor = LibraryEntry.binPrefix + name
        reloadNow()
        // After layout, because the cell or row being edited does not exist until then.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.beginRename(bin: name)
        }
    }

    /// Puts a bin's name into edit mode in whichever view is showing.
    func beginRename(bin: String) {
        layoutSubtreeIfNeeded()
        switch viewStyle {
        case .icon: gridView.beginRename(bin: bin)
        case .list: listView?.beginRename(bin: bin)
        case .column: columnView?.beginRename(bin: bin)
        }
    }

    /// The bin a paste lands in: the open one.
    private var pasteTarget: String? { browser.effectiveOpenBin }

    /// Loads an item into a channel, with the marks the library holds for it.
    private func load(_ item: LibraryItem, into channel: String) {
        guard item.isAvailable else { return }
        onItemOpened?(item, channel, model.markedRange(for: item.id))
    }

    /// Puts clips from a pasteboard into a bin. Clips copied from the library become a
    /// second entry in that bin, as a pasted copy does anywhere else; files copied in
    /// the Finder are added the same way a drop adds them.
    @discardableResult
    func paste(from board: NSPasteboard, intoBin bin: String?) -> Bool {
        guard browser.fixedItems == nil else { return false }
        let ids = LibraryBrowser.libraryIDs(on: board).filter { model.item(withID: $0) != nil }
        if !ids.isEmpty {
            let made = model.duplicateItems(ids, intoBin: bin)
            browser.selection = Set(made)
            Log.info(.app, "pasted \(made.count) clip(s) into \(bin ?? "the top level")")
            return true
        }
        let urls = LibraryBrowser.fileURLs(on: board)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls, bin)
        return true
    }

    /// True when the pasteboard holds something Paste could add.
    private func canPaste(from board: NSPasteboard) -> Bool {
        guard browser.fixedItems == nil else { return false }
        return board.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.videoboyLibraryItem.rawValue
        ])
    }

    /// The selected clips that have files — what Copy, Show in Finder and the queue
    /// can act on. A selected bin contributes its contents, as copying a folder does.
    private var selectedFileItems: [LibraryItem] {
        var items = browser.selectedItems
        for bin in browser.selectedBins {
            items += model.items.filter { $0.bin == bin }
        }
        return items.filter { $0.url != nil && $0.isAvailable }
    }

    // MARK: - Edit menu (reached through the responder chain)

    /// ⌘C. Writes the selected clips' files, so they can be pasted into another bin,
    /// another library panel, or the Finder.
    @objc func copy(_ sender: Any?) {
        let items = selectedFileItems
        guard !items.isEmpty else { return }
        let board = pasteboard
        board.clearContents()
        board.writeObjects(browser.pasteboardItems(for: items))
        Log.info(.app, "copied \(items.count) clip(s)")
    }

    /// ⌘V. Into the open bin.
    @objc func paste(_ sender: Any?) {
        paste(from: pasteboard, intoBin: pasteTarget)
    }

    /// ⌘A. Everything in the view that is showing.
    override func selectAll(_ sender: Any?) {
        guard shownPlaylist == nil, currentTab != .emu else { return }
        switch viewStyle {
        case .icon: gridView.selectAllEntries()
        case .list: listView?.outline.selectAll(nil)
        case .column: columnView?.selectAllInFocusedColumn()
        }
    }

    /// ⌘⌫. Takes the selected clips out of the library (never off the disk) and
    /// deletes the selected bins (their clips go back to the top level).
    @objc func delete(_ sender: Any?) {
        guard browser.fixedItems == nil else { return }
        let items = browser.selectedItems.map(\.id)
        let bins = browser.selectedBins
        guard !items.isEmpty || !bins.isEmpty else { return }
        if !items.isEmpty {
            model.removeItems(Set(items))
            Log.info(.app, "removed \(items.count) clip(s) from the library")
        }
        for bin in bins {
            model.deleteBin(bin)
            Log.info(.app, "deleted bin '\(bin)'; its clips are back at the top level")
        }
        browser.selection = []
    }

    // MARK: - Context-menu actions

    @objc private func menuLoad(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? String,
              let item = browser.selectedItems.first else { return }
        load(item, into: channel)
    }

    @objc private func menuQueue(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? String else { return }
        let items = selectedFileItems
        // "Play next" for several clips keeps their order: each goes in front of the
        // one queued before it, so they are inserted last-first.
        let ordered = sender.tag == 1 ? Array(items.reversed()) : items
        for item in ordered { onItemQueued?(item, channel, sender.tag == 1) }
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        let bin = sender.representedObject as? String
        let ids = browser.selectedItems.map(\.id)
        model.moveItems(ids, toBin: bin)
        Log.info(.app, "moved \(ids.count) clip(s) to \(bin ?? "the top level")")
    }

    @objc private func menuNewBinWithSelection(_ sender: NSMenuItem) {
        makeBin(filing: browser.selectedItems.map(\.id))
    }

    @objc private func menuNewBin(_ sender: NSMenuItem) {
        makeBin(filing: [])
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        let urls = selectedFileItems.compactMap(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func menuOpenBin(_ sender: NSMenuItem) {
        guard let bin = sender.representedObject as? String else { return }
        libraryOpen(.bin(bin))
    }

    @objc private func menuRenameBin(_ sender: NSMenuItem) {
        guard let bin = sender.representedObject as? String else { return }
        beginRename(bin: bin)
    }

    @objc private func menuPasteInto(_ sender: NSMenuItem) {
        paste(from: pasteboard, intoBin: sender.representedObject as? String)
    }

    @objc private func menuSelectAll(_ sender: NSMenuItem) {
        selectAll(sender)
    }

    // MARK: - Drop target (the toolbar and anywhere the views do not cover)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = libraryDragOperation(sender, intoBin: pasteTarget)
        isDropTarget = !operation.isEmpty
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        return libraryPerformDrop(sender, intoBin: pasteTarget)
    }
}

// MARK: - What gestures mean

extension LibraryPanelBody: LibraryBrowserActions {

    func libraryOpen(_ entry: LibraryEntry) {
        switch entry {
        case .bin(let name):
            // Into the bin. In columns it opens on the right, and the keyboard follows.
            browser.openBin = name
            browser.selection = viewStyle == .column ? [LibraryEntry.binPrefix + name] : []
            browser.anchor = nil
            reloadNow()
            if viewStyle == .column, let table = columnView?.binTable { window?.makeFirstResponder(table) }
            Log.info(.app, "opened bin '\(name)'")
        case .item(let item):
            let channel = destination.takeNextChannel()
            load(item, into: channel)
            updateDestinationTitles()
        }
    }

    func libraryGoUp() {
        guard let open = browser.effectiveOpenBin else { return }
        browser.openBin = BinPath.parent(of: open)
        // Back out with the bin you were in selected, as the Finder does, so ⌘↓ goes
        // straight back in.
        browser.selection = [LibraryEntry.binPrefix + open]
        browser.anchor = LibraryEntry.binPrefix + open
        reloadNow()
    }

    func librarySelectionDidChange() {
        // Nothing else draws the selection today; this is where a count readout or an
        // inspector would listen.
    }

    /// `oldName` is the bin's path; `newName` is its new own name, typed.
    func libraryRenameBin(from oldName: String, to newName: String) {
        let newPath = model.renameBin(from: oldName, to: newName)
        // The open bin may be this one or one inside it.
        if let open = browser.openBin, let moved = BinPath.replacingPrefix(of: open, oldName, with: newPath) {
            browser.openBin = moved
        }
        if browser.selection.remove(LibraryEntry.binPrefix + oldName) != nil {
            browser.selection.insert(LibraryEntry.binPrefix + newPath)
        }
        Log.info(.app, "renamed bin '\(oldName)' to '\(newPath)'")
    }

    /// Whether a drag may land in a bin, and as what.
    ///
    /// Clips from the library MOVE between bins (hold Option to file a copy instead,
    /// as in the Finder). Files from outside are ADDED. A drop that would change
    /// nothing — clips onto the bin they are already in — is refused, so the drag
    /// visibly slides back rather than appearing to succeed.
    func libraryDragOperation(_ info: NSDraggingInfo, intoBin bin: String?) -> NSDragOperation {
        let board = info.draggingPasteboard
        let ids = LibraryBrowser.libraryIDs(on: board)
        if !ids.isEmpty {
            // From the library: only the clip library can file them, and only where
            // bins are showing (not in a flat search result).
            let clips = ids.compactMap { model.item(withID: $0) }
            guard browser.showsBins, !clips.isEmpty else { return [] }
            if info.draggingSourceOperationMask == .copy { return .copy }
            return clips.allSatisfy({ $0.bin == bin }) ? [] : .move
        }
        return LibraryBrowser.fileURLs(on: board).isEmpty ? [] : .copy
    }

    func libraryPerformDrop(_ info: NSDraggingInfo, intoBin bin: String?) -> Bool {
        let operation = libraryDragOperation(info, intoBin: bin)
        guard !operation.isEmpty else { return false }
        let board = info.draggingPasteboard
        let ids = LibraryBrowser.libraryIDs(on: board).filter { model.item(withID: $0) != nil }
        if !ids.isEmpty {
            if operation == .copy {
                model.duplicateItems(ids, intoBin: bin)
                Log.info(.app, "filed copies of \(ids.count) clip(s) in \(bin ?? "the top level")")
            } else {
                model.moveItems(ids, toBin: bin)
                Log.info(.app, "moved \(ids.count) clip(s) to \(bin ?? "the top level")")
            }
            return true
        }
        let urls = LibraryBrowser.fileURLs(on: board)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls, browser.showsBins ? bin : nil)
        return true
    }

    /// The right-click menu. Built fresh each time, from the current selection, so it
    /// can never offer a stale bin list or queue onto the wrong source.
    func libraryMenu(clicked: LibraryEntry?, folder: String?) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inClipLibrary = browser.fixedItems == nil

        @discardableResult
        func add(_ title: String, _ action: Selector, _ object: Any? = nil,
                 key: String = "", tag: Int = 0, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = object
            item.tag = tag
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }

        guard let clicked else {
            // The background: things you do to a place, not to a clip.
            if inClipLibrary {
                add("New Bin", #selector(menuNewBin(_:)))
                add("Paste", #selector(menuPasteInto(_:)), folder, key: "v",
                    enabled: canPaste(from: pasteboard))
                menu.addItem(.separator())
            }
            add("Select All", #selector(menuSelectAll(_:)), key: "a")
            return menu
        }

        if let bin = clicked.binName, browser.selectedItems.isEmpty {
            // A bin, or several.
            let bins = browser.selectedBins
            add("Open", #selector(menuOpenBin(_:)), bin, enabled: bins.count == 1)
            add("Rename", #selector(menuRenameBin(_:)), bin, enabled: bins.count == 1)
            menu.addItem(.separator())
            add("Copy", #selector(copy(_:)), key: "c", enabled: !selectedFileItems.isEmpty)
            add("Paste into “\(bin)”", #selector(menuPasteInto(_:)), bin,
                enabled: bins.count == 1 && canPaste(from: pasteboard))
            menu.addItem(.separator())
            add(bins.count == 1 ? "Delete Bin" : "Delete \(bins.count) Bins",
                #selector(delete(_:)), key: "\u{8}")
                .toolTip = "The clips inside go back to the top level; nothing is removed."
            return menu
        }

        // Items.
        let items = browser.selectedItems
        let files = selectedFileItems
        let single = items.count == 1 ? items.first : nil
        for channel in focusChannels {
            add("Load into \(channel)", #selector(menuLoad(_:)), channel,
                enabled: single?.isAvailable == true)
        }
        if !playlistChannels.isEmpty {
            menu.addItem(.separator())
            for channel in playlistChannels {
                add("Add to \(channel)", #selector(menuQueue(_:)), channel, enabled: !files.isEmpty)
            }
            for channel in playlistChannels {
                add("Play Next on \(channel)", #selector(menuQueue(_:)), channel, tag: 1,
                    enabled: !files.isEmpty)
            }
        }
        menu.addItem(.separator())
        add("Copy", #selector(copy(_:)), key: "c", enabled: !files.isEmpty)
        if inClipLibrary {
            add("Paste", #selector(menuPasteInto(_:)), folder, key: "v",
                enabled: canPaste(from: pasteboard))
        }

        if inClipLibrary && browser.showsBins {
            menu.addItem(.separator())
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let currentBins = Set(items.map(\.bin))
            let top = NSMenuItem(title: "Top Level", action: #selector(menuMove(_:)), keyEquivalent: "")
            top.target = self
            top.state = currentBins == [nil] ? .on : .off
            submenu.addItem(top)
            if !model.binNames.isEmpty { submenu.addItem(.separator()) }
            for bin in model.binNames {
                // Indented under the bin that holds it, named by its own name.
                let entry = NSMenuItem(title: BinPath.leaf(of: bin), action: #selector(menuMove(_:)), keyEquivalent: "")
                entry.indentationLevel = BinPath.ancestors(of: bin).count
                entry.target = self
                entry.representedObject = bin
                entry.state = currentBins == [bin] ? .on : .off
                submenu.addItem(entry)
            }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
            add("New Bin with Selection (\(items.count) Item\(items.count == 1 ? "" : "s"))",
                #selector(menuNewBinWithSelection(_:)))
        }

        menu.addItem(.separator())
        add("Show in Finder", #selector(menuShowInFinder(_:)), enabled: !files.isEmpty)
        if inClipLibrary {
            add("Remove from Library", #selector(delete(_:)), key: "\u{8}")
                .toolTip = "Takes the clips out of the library. The files are not touched."
        }
        return menu
    }
}

extension LibraryPanelBody: NSMenuItemValidation {
    /// Enables the Edit menu's items only when they would do something here.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return !selectedFileItems.isEmpty
        case #selector(paste(_:)):
            return canPaste(from: pasteboard)
        case #selector(delete(_:)):
            return browser.fixedItems == nil
                && (!browser.selectedItems.isEmpty || !browser.selectedBins.isEmpty)
        case #selector(selectAll(_:)):
            return shownPlaylist == nil && currentTab != .emu
        default:
            return menuItem.isEnabled
        }
    }
}

/// "‹ Library  › Reel A" — where you are, and the way back out.
///
/// Also a drop target: dropping clips on it takes them out of the open bin, as
/// dropping on a path-bar folder does in the Finder.
final class LibraryPathBar: NSView {

    static let height: CGFloat = 18

    var onUp: (() -> Void)?
    weak var dropHandler: LibraryBrowserActions?

    private let back = NSButton()
    private let label = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textSecondary)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        clipsToBounds = true

        back.bezelStyle = .inline
        back.isBordered = false
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to the library")
        back.imagePosition = .imageLeading
        back.title = "Library"
        back.font = Theme.Font.tinyLabel
        back.contentTintColor = Theme.Color.accent
        back.target = self
        back.action = #selector(backPressed)
        back.toolTip = "Up one bin (⌘↑). Drop clips here to file them there."
        back.translatesAutoresizingMaskIntoConstraints = false
        addSubview(back)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            back.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
        registerForDraggedTypes([.videoboyLibraryItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// The bin above the one shown — where Back goes and where a drop lands. Nil is
    /// the top of the library.
    private var parentBin: String?

    /// Shows where the open bin is ("›  2019 › Shoot A"), and names Back after the
    /// bin it goes up to, since bins nest.
    func setBin(_ bin: String?) {
        label.stringValue = bin.map { "›  " + BinPath.display($0) } ?? ""
        parentBin = bin.flatMap(BinPath.parent)
        back.title = parentBin.map(BinPath.leaf) ?? "Library"
    }

    /// The back key, so the self-QA can click it for real.
    var backButtonForChecks: NSButton { back }

    @objc private func backPressed() { onUp?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dropHandler?.libraryDragOperation(sender, intoBin: parentBin) ?? []
        layer?.backgroundColor = operation.isEmpty ? nil : Theme.Color.accent.withAlphaComponent(0.25).cgColor
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.backgroundColor = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        return dropHandler?.libraryPerformDrop(sender, intoBin: parentBin) ?? false
    }
}

/// The queue's scrolling document, which takes clips dropped on it and queues them on
/// the channel whose queue is showing.
final class LibraryQueueDropView: FlippedView {

    weak var panel: LibraryPanelBody?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .videoboyLibraryItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    private func clips(from sender: NSDraggingInfo) -> [LibraryItem] {
        guard let panel else { return [] }
        let board = sender.draggingPasteboard
        let fromLibrary = LibraryBrowser.libraryIDs(on: board)
            .compactMap { panel.browser.model.item(withID: $0) }
            .filter { $0.url != nil }
        if !fromLibrary.isEmpty { return fromLibrary }
        return LibraryBrowser.fileURLs(on: board).map {
            LibraryItem(name: $0.lastPathComponent, badge: $0.pathExtension.uppercased(),
                        isAvailable: true, url: $0)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        panel?.shownPlaylistChannel != nil && !clips(from: sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let panel, let channel = panel.shownPlaylistChannel else { return false }
        let items = clips(from: sender)
        guard !items.isEmpty else { return false }
        for item in items { panel.onItemQueued?(item, channel, false) }
        return true
    }
}
