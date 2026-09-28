//
//  ImportModeView.swift — Import mode, the Lightroom-model import window (proposal §5).
//
//  Purpose : Lightroom Classic's importer, for video: FROM ▸ Add / Move / Copy ▸ TO
//            across the top, sources on the left, the clips in the middle (a viewer
//            opens above them on a double-click), options on the right, and the count
//            and Import along the bottom. Pick a source, tick clips, Import.
//  Inputs  : the preference store (destination, favorites), the library (for DUP and
//            bin names), and an import action handed in by the owner.
//  Outputs : an import request — URLs, method, destination, bin — which the owner runs
//            as the usual background `ImportJob` into the library and catalog.
//  Connects: ModeController (shows it), ImportSources (sidebar), HoverScrubView (the
//            library tile's hover-scrub, reused),
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
    /// "MPEG" for clips the bitstream effects work on; nil otherwise.
    let wedge: String?
    /// "⚠16:9", "⚠vertical" — a shape that is not the 4:3 canvas; nil when it fits.
    let mismatch: String?
    var isChecked: Bool
}

/// Import mode's view.
final class ImportModeView: NSView {

    private let store: PreferenceStore
    private let library: LibraryModel
    /// Runs the import. Set by the owner. `root` is the folder the clips were picked
    /// from when "Include subfolders" is on: its folder tree is kept, on disk for
    /// Copy/Move and as bins inside the chosen bin.
    var onImport: ((_ urls: [URL], _ method: ImportMethod, _ destination: URL?, _ bin: String?,
                    _ root: URL?, _ optimize: OptimizePreset?) -> Void)?

    private let listQueue = DispatchQueue(label: "videoboy.import-mode", qos: .userInitiated)

    // MARKS (proposal §5: "I/O marks stored in the catalog"). A mark on a clip already in
    // the library is written straight to it (and so to the catalog). A mark on a clip
    // not yet imported waits here, keyed by its path, and is applied when the clip
    // lands — at its new path after Move/Copy.
    typealias Marks = (inPoint: Double?, outPoint: Double?)
    private var pendingMarks: [String: Marks] = [:]
    /// Library ids by path, refreshed with each listing.
    private var libraryIDs: [String: String] = [:]
    /// Source path → where Move/Copy is putting it, for pending marks.
    private var transferTargets: [String: URL] = [:]
    private var generation = 0

    // Sidebar
    private let sourcesTable = NSTableView()
    private var rows: [(header: String?, source: ImportSource?)] = []
    private(set) var currentSource: ImportSource?

    // Centre: header, filter bar, viewer (only once a clip is opened), grid
    private let countsLabel = Controls.label("", font: Theme.Import.bodyFont, color: Theme.Color.textSecondary)
    /// Which clips the grid shows. Its labels carry their counts.
    private let filter = Controls.segmented(["All Clips", "New Clips", "In Library"], selected: 0)
    private let includeSubfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 170, minValue: 120, maxValue: 280, target: nil, action: nil)
    private let collection = NSCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    /// Shown over the grid when there is nothing in it, saying why.
    private let emptyState = Controls.label("Choose a folder or device on the left.",
                                            font: Theme.Import.bodyFont, color: Theme.Color.textTertiary)
    private var isReading = false
    private(set) var entries: [ImportEntry] = []
    private var shown: [Int] = []  // indices into `entries` after the filter

    // Viewer: closed until a clip is double-clicked, so it is never a black box
    // taking a third of the screen for nothing.
    let playerView = AVPlayerView()
    private let viewerBox = NSStackView()
    private let viewerTitle = Controls.label("", font: Theme.Import.emphasisFont, color: Theme.Color.textPrimary)
    private var viewerHeight: NSLayoutConstraint?

    // Inspector
    let methodControl = Controls.segmented(["Add", "Move", "Copy"], selected: 0)
    private let methodDescription = Controls.label("", font: Theme.Import.bodyFont, color: Theme.Color.textSecondary)
    private var destination: URL
    /// Where the clips come from, as the Finder shows a path.
    private let sourcePath = NSPathControl()
    /// The folder `sourcePath` shows (or is resolving). Setting a path control's `url`
    /// looks up every component's icon on the main thread — ~10 ms cold, far more on a
    /// card or a network share — so the items are built on `listQueue` instead, once
    /// per folder rather than on every refresh.
    private var sourcePathShown: URL?
    /// Where Move/Copy put them: a pop-up path control, AppKit's own "choose a folder".
    let destinationControl = NSPathControl()
    private let destinationNote = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
    let subfolderCheck = NSButton(checkboxWithTitle: "Put them in a subfolder", target: nil, action: nil)
    private let subfolderField = NSTextField(string: "")
    let binPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let skipDuplicates = NSButton(checkboxWithTitle: "Skip clips already in the library", target: nil, action: nil)
    let optimizeCheck = NSButton(checkboxWithTitle: "Convert copies to MPEG-2", target: nil, action: nil)
    private let optimizeNote = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
    /// What pressing Import will do, in a sentence.
    private let summaryLabel = Controls.label("", font: Theme.Import.bodyFont, color: Theme.Color.textSecondary)
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
    //
    // Three columns (proposal §5): SOURCES | the clips | an inspector saying how they
    // come in. Redesigned 2026-09-28 (owner: "ugly and confusing"): the centre opens
    // on a header naming the folder and what is new in it, not on an empty black
    // viewer; the two "All"s (a filter and a tick-everything) are no longer side by
    // side; the inspector reads top to bottom as a sentence — HOW, WHERE, OPTIMIZE,
    // LIBRARY — and ends in a line saying exactly what Import will do, above one
    // large Import button.

    private func build() {
        let header = buildHeader()
        let footer = buildFooter()
        // Three resizable columns — AppKit's split view, as Mail, Xcode and Lightroom
        // lay out source list / content / inspector. Widths are remembered.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "ImportModeColumns"
        let sidebar = buildSidebar(), centre = buildCentre(), inspector = buildRightPane()
        let centreHolder = NSView()
        centre.translatesAutoresizingMaskIntoConstraints = false
        centreHolder.addSubview(centre)
        let pad = Theme.Import.padding
        NSLayoutConstraint.activate([
            centre.topAnchor.constraint(equalTo: centreHolder.topAnchor),
            centre.bottomAnchor.constraint(equalTo: centreHolder.bottomAnchor),
            centre.leadingAnchor.constraint(equalTo: centreHolder.leadingAnchor, constant: pad),
            centre.trailingAnchor.constraint(equalTo: centreHolder.trailingAnchor, constant: -pad)
        ])
        for pane in [sidebar, centreHolder, inspector] { split.addArrangedSubview(pane) }
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        split.setHoldingPriority(.init(260), forSubviewAt: 2)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Import.sidebarMinimumWidth).isActive = true
        inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Import.inspectorMinimumWidth).isActive = true
        centreHolder.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Import.centreMinimumWidth).isActive = true
        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Theme.Import.sidebarWidth)
        let inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: Theme.Import.inspectorWidth)
        for width in [sidebarWidth, inspectorWidth] { width.priority = .init(200); width.isActive = true }

        for view in [header, split, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Import.headerHeight),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.Import.footerHeight)
        ])
        applyMethodRules()
    }

    /// From: ▸ Add | Move | Copy ▸ To: — Lightroom's sentence, in standard controls:
    /// path controls for the two folders, a segmented control for the method.
    private func buildHeader() -> NSView {
        func caption(_ text: String) -> NSTextField {
            Controls.label(text, font: Theme.Import.bodyFont, color: Theme.Color.textSecondary)
        }
        sourcePath.pathStyle = .standard
        sourcePath.isEditable = false
        sourcePath.controlSize = .regular
        sourcePath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourcePath.setAccessibilityIdentifier("import-source-path")
        let from = Controls.row([caption("From:"), sourcePath], spacing: 6)

        methodControl.target = self
        methodControl.action = #selector(methodChanged)
        methodControl.setAccessibilityIdentifier("import-method")
        methodControl.segmentDistribution = .fillEqually
        methodControl.controlSize = .large
        methodControl.translatesAutoresizingMaskIntoConstraints = false
        methodControl.widthAnchor.constraint(equalToConstant: 240).isActive = true
        methodDescription.alignment = .center
        let how = Controls.column([methodControl, methodDescription], spacing: 4)
        how.alignment = .centerX

        destinationControl.pathStyle = .popUp       // its menu ends in "Choose…", as AppKit's does
        destinationControl.url = destination
        destinationControl.delegate = self
        destinationControl.target = self
        destinationControl.action = #selector(destinationChosen)
        destinationControl.setAccessibilityIdentifier("choose-destination")
        let to = Controls.row([caption("To:"), destinationControl], spacing: 6)

        let bar = NSView()
        for view in [from, how, to] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        let pad = Theme.Import.padding
        NSLayoutConstraint.activate([
            how.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            how.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            from.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: pad),
            from.trailingAnchor.constraint(lessThanOrEqualTo: how.leadingAnchor, constant: -pad),
            from.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            to.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -pad),
            to.leadingAnchor.constraint(greaterThanOrEqualTo: how.trailingAnchor, constant: pad),
            to.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: .init("source"))
        sourcesTable.addTableColumn(column)
        sourcesTable.headerView = nil
        sourcesTable.style = .sourceList
        sourcesTable.rowSizeStyle = .default
        sourcesTable.dataSource = self
        sourcesTable.delegate = self
        sourcesTable.menu = sourceMenu()
        sourcesTable.setAccessibilityIdentifier("import-sources")
        let scroll = NSScrollView()
        scroll.documentView = sourcesTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // The source list's own buttons: + and − under the list, small-square, with
        // the system's template images — as Finder's and System Settings' lists have.
        func squareButton(_ image: NSImage.Name, _ tip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(named: image) ?? NSImage(), target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return button
        }
        let buttons = Controls.row([squareButton(NSImage.addTemplateName, "Add a folder to Favorites", #selector(addFavorite)),
                                    squareButton(NSImage.removeTemplateName, "Remove the selected favorite", #selector(removeFavorite)),
                                    Controls.spacer()], spacing: 0)
        includeSubfolders.target = self
        includeSubfolders.action = #selector(subfoldersChanged)
        includeSubfolders.state = .on

        let stack = Controls.column([scroll, includeSubfolders, buttons], spacing: 8)
        stack.alignment = .leading
        scroll.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    /// Right-click on a source: Eject for a removable device, Remove for a favorite.
    private func sourceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func buildCentre() -> NSView {
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityIdentifier("import-filter")
        filter.controlSize = .regular
        let tabs = NSView()
        filter.translatesAutoresizingMaskIntoConstraints = false
        tabs.addSubview(filter)
        NSLayoutConstraint.activate([
            filter.centerXAnchor.constraint(equalTo: tabs.centerXAnchor),
            filter.topAnchor.constraint(equalTo: tabs.topAnchor),
            filter.bottomAnchor.constraint(equalTo: tabs.bottomAnchor)
        ])

        // Viewer: a strip with the clip's name and a close key, then the player.
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect   // letterboxed, never deformed
        playerView.setAccessibilityIdentifier("import-viewer")
        playerView.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(image: NSImage(named: NSImage.stopProgressTemplateName) ?? NSImage(),
                             target: self, action: #selector(toggleViewer))
        close.isBordered = false
        close.toolTip = "Close the viewer (V)"
        let viewerHeaderRow = Controls.row([viewerTitle, Controls.spacer(),
                                            Controls.label("J K L shuttle · I O marks", font: Theme.Font.label,
                                                           color: Theme.Color.textTertiary), close], spacing: 10)
        viewerBox.orientation = .vertical
        viewerBox.spacing = 6
        viewerBox.addArrangedSubview(viewerHeaderRow)
        viewerBox.addArrangedSubview(playerView)
        viewerBox.translatesAutoresizingMaskIntoConstraints = false
        let height = viewerBox.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        viewerHeight = height
        viewerBox.isHidden = true
        for view in [viewerHeaderRow, playerView] as [NSView] {
            view.widthAnchor.constraint(equalTo: viewerBox.widthAnchor).isActive = true
        }

        let pictureWidth = CGFloat(sizeSlider.doubleValue)
        layout.itemSize = NSSize(width: pictureWidth,
                                 height: pictureWidth * Theme.Import.pictureAspect + Theme.Import.captionHeight)
        layout.minimumInteritemSpacing = Theme.Import.tileSpacing
        layout.minimumLineSpacing = Theme.Import.tileSpacing
        layout.sectionInset = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
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
        emptyState.alignment = .center
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -40)
        ])

        // Below the grid: tick everything or nothing, and the thumbnail size between a
        // small and a large picture — Finder's and Photos' size control.
        let checkAll = Controls.button("Check All", target: self, action: #selector(checkAll))
        let uncheckAll = Controls.button("Uncheck All", target: self, action: #selector(checkNone))
        checkAll.setAccessibilityIdentifier("import-check-all")
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.controlSize = .small
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        func picture(_ size: CGFloat) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: size, weight: .regular)
            view.contentTintColor = Theme.Color.textTertiary
            return view
        }
        let bar = Controls.row([checkAll, uncheckAll, Controls.spacer(), picture(9), sizeSlider, picture(14)],
                               spacing: 8)

        let stack = Controls.column([tabs, viewerBox, scroll, bar], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        for view in [tabs, viewerBox, scroll, bar] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refreshHeader()
        return stack
    }

    /// Options, as a form: right-aligned "Label:" column, controls beside — System
    /// Settings' layout (NSGridView). A greyed option carries its reason on the row below.
    private func buildRightPane() -> NSView {
        methodDescription.lineBreakMode = .byWordWrapping
        methodDescription.maximumNumberOfLines = 2
        subfolderCheck.title = ""
        subfolderCheck.target = self
        subfolderCheck.action = #selector(methodChanged)
        subfolderField.placeholderString = "Subfolder name"
        subfolderField.target = self
        subfolderField.action = #selector(methodChanged)
        binPopUp.target = self
        binPopUp.action = #selector(binChanged)
        skipDuplicates.state = .on
        skipDuplicates.target = self
        skipDuplicates.action = #selector(methodChanged)
        optimizeCheck.toolTip = "Convert each copy to MPEG-2 on the SD canvas (the bitstream effects "
            + "work on it), linked to the original and played in its place"
        optimizeCheck.target = self
        optimizeCheck.action = #selector(methodChanged)
        refreshBins()

        func label(_ text: String) -> NSTextField {
            Controls.label(text, font: Theme.Import.bodyFont, color: Theme.Color.textSecondary)
        }
        for note in [optimizeNote, destinationNote] {
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 3
            note.preferredMaxLayoutWidth = Theme.Import.inspectorWidth - 110
        }
        let subfolder = Controls.row([subfolderCheck, subfolderField], spacing: 4)
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            // Row indices matter to the padding below: keep them in step.
            [label("Duplicates:"), skipDuplicates],
            [label("Optimize:"), optimizeCheck],
            [empty, optimizeNote],
            [label("Subfolder:"), subfolder],
            [empty, destinationNote],
            [label("Bin:"), binPopUp]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        // A little air between the three groups (duplicates · optimize · where).
        grid.row(at: 1).topPadding = 8   // Optimize
        grid.row(at: 3).topPadding = 8   // Subfolder
        grid.row(at: 5).topPadding = 8   // Bin
        subfolderField.translatesAutoresizingMaskIntoConstraints = false
        subfolderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let pane = Controls.column([grid, Controls.spacer()], spacing: 0)
        // The form stays inside its column: the field gives way, never the edge.
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(lessThanOrEqualTo: pane.widthAnchor, constant: -2 * Theme.Import.padding).isActive = true
        pane.alignment = .leading
        let pad = Theme.Import.padding
        pane.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        return pane
    }

    /// The count and size on the left, what Import will do, then Import — the default
    /// button (Return), which AppKit draws in the accent colour.
    private func buildFooter() -> NSView {
        countsLabel.alignment = .left
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        importButton.bezelStyle = .rounded
        importButton.controlSize = .large
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.setAccessibilityIdentifier("import-go")
        let row = Controls.row([countsLabel, Controls.spacer(), summaryLabel, importButton], spacing: 16)
        let pad = Theme.Import.padding
        row.edgeInsets = NSEdgeInsets(top: 0, left: pad, bottom: 0, right: pad)
        let line = NSBox()
        line.boxType = .separator
        let footer = NSView()
        for view in [line, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: footer.topAnchor),
            line.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            row.topAnchor.constraint(equalTo: line.bottomAnchor),
            row.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor)
        ])
        return footer
    }

    // MARK: - Greying (proposal §5: greyed, never hidden) and the summary

    var method: ImportMethod {
        [ImportMethod.add, .move, .copy][max(methodControl.selectedSegment, 0)]
    }

    /// Destination and Optimize follow the method; Move follows the source. Greyed
    /// controls say WHY they are grey, in a line under them.
    private func applyMethodRules() {
        let allowsMove = currentSource?.allowsMove ?? true
        methodControl.setEnabled(allowsMove, forSegment: 1)
        if !allowsMove, methodControl.selectedSegment == 1 { methodControl.selectedSegment = 2 }
        switch method {
        case .add:
            methodDescription.stringValue = "Leave the files where they are and add them to the library."
        case .move:
            methodDescription.stringValue = "Move the files into the destination folder, then add them."
        case .copy:
            methodDescription.stringValue = "Copy the files into the destination folder and add the copies. "
                + "The originals stay where they are."
        }
        let usesDestination = method.usesDestination
        destinationControl.isEnabled = usesDestination
        subfolderCheck.isEnabled = usesDestination
        subfolderField.isEnabled = usesDestination && subfolderCheck.state == .on
        destinationNote.stringValue = usesDestination ? ""
            : "Not used — Add leaves the files where they are."
        if !allowsMove { destinationNote.stringValue += (destinationNote.stringValue.isEmpty ? "" : " ")
            + "Move is off: this source is read-only or removable." }
        destinationNote.isHidden = destinationNote.stringValue.isEmpty
        // Optimize only with COPY (proposal §5: Add and Move grey it out).
        optimizeCheck.isEnabled = method == .copy
        optimizeNote.stringValue = method == .copy ? "" : "Only when copying."
        optimizeNote.isHidden = optimizeNote.stringValue.isEmpty
        updateImportButton()
    }

    private func updateImportButton() {
        let count = importableURLs().count
        importButton.title = count == 0 ? "Import" : count == 1 ? "Import 1 Clip" : "Import \(count) Clips"
        importButton.isEnabled = count > 0
        refreshSummary(count: count)
        refreshSelectionMenu()
    }

    /// One sentence: what Import will do, with what, where.
    private func refreshSummary(count: Int) {
        guard currentSource != nil else {
            summaryLabel.stringValue = "Choose a source on the left to see its clips."
            return
        }
        guard count > 0 else {
            summaryLabel.stringValue = entries.isEmpty ? "Nothing to import here." : "Tick the clips you want to import."
            return
        }
        let clips = count == 1 ? "1 clip" : "\(count) clips"
        var sentence: String
        switch method {
        case .add: sentence = "Add \(clips) to the library, where they are"
        case .move: sentence = "Move \(clips) to \(resolvedDestination?.lastPathComponent ?? "the destination")"
        case .copy: sentence = "Copy \(clips) to \(resolvedDestination?.lastPathComponent ?? "the destination")"
        }
        if let bin = chosenBin { sentence += ", in the bin “\(BinPath.leaf(of: bin))”" }
        sentence += "."
        if method == .copy, optimizeCheck.state == .on {
            sentence += " Each is also converted for the SD canvas."
        }
        let skipped = entries.filter { $0.isChecked && $0.isDuplicate }.count
        if skipDuplicates.state == .on, skipped > 0 {
            sentence += " \(skipped) already in the library \(skipped == 1 ? "is" : "are") skipped."
        }
        summaryLabel.stringValue = sentence
    }

    /// A folder picked from the destination's pop-up ("Choose…" or a parent folder).
    @objc private func destinationChosen() {
        guard let url = destinationControl.url else { return }
        destination = url
        updateImportButton()
    }

    /// Points Move/Copy somewhere else — for self-QA (scratch folders only).
    func setDestinationForChecks(_ url: URL) {
        destination = url
        destinationControl.url = url
        updateImportButton()
    }

    /// Whether the destination controls are live — for self-QA.
    var destinationEnabled: Bool { destinationControl.isEnabled }
    var moveEnabled: Bool { methodControl.isEnabled(forSegment: 1) }
    /// The summary sentence and the header — for self-QA.
    var summaryForChecks: String { summaryLabel.stringValue }
    var headerForChecks: (title: String, counts: String) {
        (currentSource.map { $0.url.lastPathComponent } ?? "Choose a source", countsLabel.stringValue)
    }
    var isViewerOpen: Bool { !viewerBox.isHidden }

    // MARK: - Header, filter counts, the selection menu

    /// The folder's name and path, and what is in it — or why there is nothing.
    private func refreshHeader() {
        guard let source = currentSource else {
            sourcePathShown = nil
            sourcePath.pathItems = []
            sourcePath.placeholderString = "Choose a source on the left"
            countsLabel.stringValue = ""
            emptyState.stringValue = "Choose a folder or device on the left."
            emptyState.isHidden = false
            return
        }
        if sourcePathShown != source.url { showSourcePath(source.url) }
        let total = entries.count
        let fresh = entries.filter { !$0.isDuplicate }.count
        let known = total - fresh
        if isReading {
            countsLabel.stringValue = "Reading…"
        } else if total == 0 {
            countsLabel.stringValue = ""
        } else {
            let bytes = entries.reduce(0) { $0 + $1.size }
            let ticked = entries.filter(\.isChecked).count
            countsLabel.stringValue = "\(ticked) of \(total) clip\(total == 1 ? "" : "s") checked · "
                + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        filter.setLabel("All Clips  \(total)", forSegment: 0)
        filter.setLabel("New Clips  \(fresh)", forSegment: 1)
        filter.setLabel("In Library  \(known)", forSegment: 2)
        if isReading {
            emptyState.stringValue = "Reading \(source.title)…"
        } else if total == 0 {
            emptyState.stringValue = "No video clips in \(source.title)"
                + (includeSubfolders.state == .on ? "." : ". Try including subfolders.")
        } else if shown.isEmpty {
            emptyState.stringValue = filter.selectedSegment == 1
                ? "Everything here is already in the library." : "Nothing here is in the library yet."
        }
        emptyState.isHidden = !shown.isEmpty && !isReading
    }

    /// Fills the From: path off the main thread: names and icons from the folder up to
    /// its volume, as the Finder shows them.
    private func showSourcePath(_ url: URL) {
        sourcePathShown = url
        listQueue.async { [weak self] in
            var components: [(title: String, icon: NSImage)] = []
            var current = url.standardizedFileURL
            while true {
                // A copy: the workspace may hand back a shared, cached image, and this
                // one is resized off the main thread.
                let icon = (NSWorkspace.shared.icon(forFile: current.path).copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                components.insert((FileManager.default.displayName(atPath: current.path), icon), at: 0)
                let volume = (try? current.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
                let parent = current.deletingLastPathComponent()
                if volume || parent.path == current.path { break }
                current = parent
            }
            Self.onMain {
                guard let self, self.sourcePathShown == url else { return }
                self.sourcePath.pathItems = components.map { component in
                    let item = NSPathControlItem()
                    item.title = component.title
                    item.image = component.icon
                    return item
                }
            }
        }
    }

    /// The header's counts include how many are ticked; nothing else to refresh.
    private func refreshSelectionMenu() { refreshHeader() }

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
        libraryIDs = library.idsByPath()
        isReading = true
        entries = []
        applyFilter()
        listQueue.async { [weak self] in
            let listed = Self.list(source.url, deep: deep, libraryPaths: libraryPaths)
            Self.onMain {
                guard let self, self.generation == wanted else { return }
                self.entries = listed
                self.isReading = false
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
            let wedge: String? = ClipDecoders.mpegExtensions.contains(ext) ? "MPEG" : nil
            return ImportEntry(url: url, size: bytes, isDuplicate: duplicate, wedge: wedge,
                               mismatch: wedge == nil ? shapeWarning(url) : nil, isChecked: !duplicate)
        }
    }

    /// "⚠16:9" / "⚠vertical" when a clip's upright shape is not 4:3. MPEG is SD here
    /// and not probed.
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
        applyPendingMarks()
        libraryRefresh?.cancel()
        guard let source = currentSource else { return }
        let work = DispatchWorkItem { [weak self] in self?.show(source) }
        libraryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Marks

    /// The marks a tile shows: the library's, or ones waiting for the import.
    fileprivate func marks(for url: URL) -> Marks {
        let path = url.standardizedFileURL.path
        if let id = libraryIDs[path] { return library.marks(for: id) }
        return pendingMarks[path] ?? (nil, nil)
    }

    /// I, O or X on a tile or in the viewer.
    fileprivate func setMarks(_ marks: Marks, for url: URL) {
        let path = url.standardizedFileURL.path
        if let id = libraryIDs[path] ?? library.idsByPath()[path] {
            library.setMarks(inPoint: marks.inPoint, outPoint: marks.outPoint, for: id)
        } else if marks.inPoint == nil && marks.outPoint == nil {
            pendingMarks[path] = nil
        } else {
            pendingMarks[path] = marks
        }
    }

    /// Hands waiting marks to clips that have now arrived in the library.
    private func applyPendingMarks() {
        guard !pendingMarks.isEmpty else { return }
        let ids = library.idsByPath()
        for (path, marks) in pendingMarks {
            let landed = transferTargets[path]?.standardizedFileURL.path ?? path
            guard let id = ids[landed] else { continue }
            library.setMarks(inPoint: marks.inPoint, outPoint: marks.outPoint, for: id)
            pendingMarks[path] = nil
            transferTargets[path] = nil
        }
    }

    /// Marks waiting for an import — for self-QA.
    var pendingMarkCountForChecks: Int { pendingMarks.count }

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
        refreshHeader()
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
        viewerTitle.stringValue = url.lastPathComponent
        if viewerBox.isHidden { toggleViewer() }
        shuttle = 0
        window?.makeFirstResponder(self)
    }

    // MARK: - Viewer keys: J/K/L shuttle, ←/→ frame step, I/O marks

    override var acceptsFirstResponder: Bool { true }

    /// The shuttle speed J and L have reached (negative is reverse).
    private var shuttle: Float = 0

    override func keyDown(with event: NSEvent) {
        guard let player = playerView.player,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              handleViewerKey(event.charactersIgnoringModifiers?.lowercased() ?? "",
                              keyCode: event.keyCode, player: player)
        else { return super.keyDown(with: event) }
    }

    /// One viewer key; false when it is not one of ours. Exposed for self-QA.
    @discardableResult
    func handleViewerKey(_ key: String, keyCode: UInt16 = 0, player: AVPlayer) -> Bool {
        switch key {
        case "l":
            shuttle = shuttle <= 0 ? 1 : min(shuttle * 2, 8)
            player.rate = shuttle
        case "j":
            shuttle = shuttle >= 0 ? -1 : max(shuttle * 2, -8)
            player.rate = shuttle
        case "k":
            shuttle = 0
            player.pause()
        case "i", "o", "x":
            guard let url = viewerURL, let item = player.currentItem else { return false }
            let duration = CMTimeGetSeconds(item.duration)
            let position = duration > 0 ? CMTimeGetSeconds(player.currentTime()) / duration : 0
            var marks = self.marks(for: url)
            if key == "i" { marks.inPoint = position; if let out = marks.outPoint, out < position { marks.outPoint = nil } }
            if key == "o" { marks.outPoint = position; if let into = marks.inPoint, into > position { marks.inPoint = nil } }
            if key == "x" { marks = (nil, nil) }
            setMarks(marks, for: url)
            collection.reloadData()
        default:
            // ← and → step one frame (paused).
            guard keyCode == 123 || keyCode == 124, let item = player.currentItem else { return false }
            shuttle = 0
            player.pause()
            item.step(byCount: keyCode == 124 ? 1 : -1)
        }
        return true
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

    /// The folder whose tree the import keeps: the source, when its subfolders are
    /// included. Without them every clip is in the source folder itself anyway.
    private var importRoot: URL? {
        includeSubfolders.state == .on ? currentSource?.url : nil
    }

    /// The bin chosen: the source folder's name, none, or an existing bin (a path;
    /// the menu shows it indented under the bins that hold it).
    private var chosenBin: String? {
        switch binPopUp.indexOfSelectedItem {
        case 0: return currentSource?.title
        case 1: return nil
        default: return binPopUp.selectedItem?.representedObject as? String
        }
    }

    @objc func importPressed() {
        let urls = importableURLs()
        guard !urls.isEmpty else { return }
        Log.info(.app, "import mode: \(method.rawValue) \(urls.count) clips"
            + (resolvedDestination.map { " to \($0.path)" } ?? ""))
        if let destination = resolvedDestination {
            // Where each file will land (FileTransfer numbers a taken name, which this
            // cannot predict; such a clip keeps its marks waiting until matched by hand).
            for url in urls where pendingMarks[url.standardizedFileURL.path] != nil {
                transferTargets[url.standardizedFileURL.path] = FileTransfer.targetFolder(
                    for: url, in: destination, keepingFoldersBelow: importRoot
                ).appendingPathComponent(url.lastPathComponent)
            }
        }
        let optimize = method == .copy && optimizeCheck.state == .on
            ? OptimizePreset.compact : nil
        onImport?(urls, method, resolvedDestination, chosenBin, importRoot, optimize)
    }

    private func refreshBins() {
        let selectedIndex = binPopUp.indexOfSelectedItem
        let selectedBin = binPopUp.selectedItem?.representedObject as? String
        binPopUp.removeAllItems()
        binPopUp.addItems(withTitles: ["Source folder's name", "No bin"])
        for bin in library.binNames {
            let item = NSMenuItem(title: BinPath.leaf(of: bin), action: nil, keyEquivalent: "")
            item.representedObject = bin
            item.indentationLevel = BinPath.ancestors(of: bin).count
            binPopUp.menu?.addItem(item)
        }
        if let selectedBin, let index = binPopUp.itemArray.firstIndex(where: { $0.representedObject as? String == selectedBin }) {
            binPopUp.selectItem(at: index)
        } else if selectedIndex == 1 {
            binPopUp.selectItem(at: 1)
        }
    }

    // MARK: - Actions

    @objc private func methodChanged() { applyMethodRules() }
    @objc private func binChanged() { updateImportButton() }
    @objc private func filterChanged() { applyFilter() }
    @objc private func subfoldersChanged() { if let currentSource { show(currentSource) } }
    @objc private func sizeChanged() {
        let width = CGFloat(sizeSlider.doubleValue)
        layout.itemSize = NSSize(width: width, height: width * Theme.Import.pictureAspect + Theme.Import.captionHeight)
    }
    @objc private func checkAll() { setAllChecked(true) }
    @objc private func checkNone() { setAllChecked(false) }

    func setAllChecked(_ checked: Bool) {
        for index in shown { entries[index].isChecked = checked }
        collection.reloadData()
        updateImportButton()
    }

    /// Opens or closes the viewer (its ✕, or V). Closing pauses it.
    @objc func toggleViewer() {
        let opening = viewerBox.isHidden
        guard opening == false || playerView.player != nil else { return }   // nothing to show yet
        viewerBox.isHidden = !opening
        viewerHeight?.constant = opening ? Theme.Import.viewerHeight : 0
        if !opening { playerView.player?.pause() }
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
        tile.onMarks = { [weak self] url, marks in self?.setMarks(marks, for: url) }
        tile.showMarks(marks(for: entries[shown[index]].url))
        return tile
    }
}

/// A tile, as Photos and Lightroom draw one: the picture (the library's hover-scrub,
/// I/O marks and all) with a checkbox in its corner; under it the name and, in
/// secondary text, what matters about the file — codec, size, already in the library.
/// A shape that does not fit the canvas gets the system's warning symbol. Unchecked
/// clips step back.
final class ImportTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("import-tile")

    private let picture = HoverScrubView()
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = Controls.label("", font: Theme.Import.bodyFont, color: Theme.Color.textPrimary)
    private let details = Controls.label("", font: Theme.Font.label, color: Theme.Color.textSecondary)
    private let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                     accessibilityDescription: "Not the canvas shape") ?? NSImage())
    private var url: URL?
    private var badgeParts: [String] = []
    var onChecked: ((Bool) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onMarks: ((URL, ImportModeView.Marks) -> Void)?

    override func loadView() {
        let tile = ImportTileView()
        tile.onDoubleClick = { [weak self] in if let url = self?.url { self?.onOpen?(url) } }
        picture.onMarksChanged = { [weak self] inPoint, outPoint in
            if let url = self?.url { self?.onMarks?(url, (inPoint, outPoint)) }
        }
        picture.wantsLayer = true
        picture.layer?.cornerRadius = Theme.Import.tileCornerRadius
        picture.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        details.lineBreakMode = .byTruncatingTail
        warning.contentTintColor = .systemYellow
        warning.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        check.target = self
        check.action = #selector(checkChanged)
        let caption = Controls.row([warning, name], spacing: 4)
        for view in [picture, check, caption, details] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: tile.topAnchor),
            picture.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            picture.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -4),
            check.topAnchor.constraint(equalTo: picture.topAnchor, constant: 5),
            check.leadingAnchor.constraint(equalTo: picture.leadingAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: details.topAnchor, constant: -1),
            details.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: tile.bottomAnchor)
        ])
        view = tile
    }

    func configure(_ entry: ImportEntry) {
        url = entry.url
        picture.item = ShellController.libraryItem(for: entry.url)
        check.state = entry.isChecked ? .on : .off
        name.stringValue = entry.url.lastPathComponent
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        details.stringValue = [entry.wedge, size, entry.isDuplicate ? "In Library" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        warning.isHidden = entry.mismatch == nil
        warning.toolTip = entry.mismatch.map { "\($0.replacingOccurrences(of: "⚠", with: "")) — not the canvas's shape; it will be fitted" }
        badgeParts = [entry.isDuplicate ? "DUP" : nil, entry.wedge, entry.mismatch].compactMap { $0 }
        applyLook()
    }

    /// Unchecked clips step back, so what will be imported stands out.
    private func applyLook() {
        let checked = check.state == .on
        picture.alphaValue = checked ? 1 : 0.45
        name.textColor = checked ? Theme.Color.textPrimary : Theme.Color.textTertiary
    }

    func showMarks(_ marks: ImportModeView.Marks) {
        picture.setInOut(inPoint: marks.inPoint, outPoint: marks.outPoint)
    }

    /// The picture — for self-QA (it takes I and O while hovered).
    var pictureForChecks: HoverScrubView { picture }

    /// The badge text — for self-QA.
    var badgeText: String { badgeParts.joined(separator: " ") }
    /// The secondary line under the name — for self-QA.
    var detailsText: String { details.stringValue }

    @objc private func checkChanged() {
        applyLook()
        onChecked?(check.state == .on)
    }
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

// MARK: - The destination's pop-up and the source list's menu

extension ImportModeView: NSPathControlDelegate {
    /// "Choose…" picks a folder, and may make one — AppKit's own panel, configured.
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.message = "Where should moved or copied clips go?"
    }
}

extension ImportModeView: NSMenuDelegate {
    /// Right-click on a source: Eject for a removable device, Remove for a favorite.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = sourcesTable.clickedRow
        guard rows.indices.contains(row), let source = rows[row].source else { return }
        sourcesTable.selectRowIndexes([row], byExtendingSelection: false)
        if source.isEjectable {
            menu.addItem(withTitle: "Eject “\(source.title)”", action: #selector(ejectSelected), keyEquivalent: "").target = self
        }
        if source.section == .favorites {
            menu.addItem(withTitle: "Remove from Favorites", action: #selector(removeFavorite), keyEquivalent: "").target = self
        }
    }
}
