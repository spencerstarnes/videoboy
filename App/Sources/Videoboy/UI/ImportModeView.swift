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
    private let titleLabel = Controls.label("Import", font: Theme.Import.titleFont, color: Theme.Color.textPrimary)
    private let pathLabel = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
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
    private let destinationName = Controls.label("", font: Theme.Import.emphasisFont, color: Theme.Color.textPrimary)
    private let destinationPath = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
    private let destinationIcon = NSImageView()
    let destinationButton = NSButton(title: "Change…", target: nil, action: nil)
    private let destinationNote = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
    let subfolderCheck = NSButton(checkboxWithTitle: "Put them in a subfolder", target: nil, action: nil)
    private let subfolderField = NSTextField(string: "")
    let binPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let skipDuplicates = NSButton(checkboxWithTitle: "Skip clips already in the library", target: nil, action: nil)
    let optimizeCheck = NSButton(checkboxWithTitle: "Convert copies for the SD canvas", target: nil, action: nil)
    let optimizePreset = SetupChoices.popUp(SetupChoices.optimizePresetItems)
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
        let sidebar = buildSidebar()
        let centre = buildCentre()
        let right = buildRightPane()
        let footer = buildFooter()
        for view in [header, sidebar, centre, right, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = Theme.Import.padding
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Import.headerHeight),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.Import.footerHeight),

            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Theme.Import.sidebarWidth),
            right.topAnchor.constraint(equalTo: header.bottomAnchor),
            right.bottomAnchor.constraint(equalTo: footer.topAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: Theme.Import.inspectorWidth),
            centre.topAnchor.constraint(equalTo: header.bottomAnchor),
            centre.bottomAnchor.constraint(equalTo: footer.topAnchor),
            centre.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: pad),
            centre.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -pad)
        ])
        applyMethodRules()
    }

    /// FROM ▸ how ▸ TO, across the top — Lightroom's sentence. What will happen is
    /// readable before anything else is touched.
    private func buildHeader() -> NSView {
        func tag(_ text: String) -> NSTextField {
            let label = Controls.label(text, font: Theme.Import.sectionFont, color: Theme.Color.textSecondary)
            label.wantsLayer = true
            label.layer?.backgroundColor = Theme.Color.panelFill.cgColor
            label.layer?.cornerRadius = Theme.Import.pillCornerRadius
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 34).isActive = true
            return label
        }
        func arrow() -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: nil) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            view.contentTintColor = Theme.Color.textSecondary
            return view
        }
        pathLabel.lineBreakMode = .byTruncatingHead
        titleLabel.lineBreakMode = .byTruncatingMiddle
        for label in [pathLabel, titleLabel, destinationName, destinationPath] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let fromTexts = Controls.column([titleLabel, pathLabel], spacing: 1)
        fromTexts.alignment = .leading
        let from = Controls.row([tag("FROM"), fromTexts], spacing: 10)

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

        destinationIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        destinationIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        destinationName.lineBreakMode = .byTruncatingMiddle
        destinationPath.lineBreakMode = .byTruncatingHead
        destinationButton.bezelStyle = .rounded
        destinationButton.target = self
        destinationButton.action = #selector(chooseDestination)
        destinationButton.setAccessibilityIdentifier("choose-destination")
        showDestination()
        let toTexts = Controls.column([destinationName, destinationPath], spacing: 1)
        toTexts.alignment = .leading
        let to = Controls.row([tag("TO"), destinationIcon, toTexts, destinationButton], spacing: 10)

        for side in [from, to] {
            side.translatesAutoresizingMaskIntoConstraints = false
        }
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.Color.bar.cgColor
        let fromArrow = arrow(), toArrow = arrow()
        for view in [from, fromArrow, how, toArrow, to] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        let pad = Theme.Import.padding
        NSLayoutConstraint.activate([
            how.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            how.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            from.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: pad),
            from.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            fromArrow.leadingAnchor.constraint(greaterThanOrEqualTo: from.trailingAnchor, constant: 10),
            fromArrow.trailingAnchor.constraint(equalTo: how.leadingAnchor, constant: -24),
            fromArrow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            toArrow.leadingAnchor.constraint(equalTo: how.trailingAnchor, constant: 24),
            toArrow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            to.leadingAnchor.constraint(greaterThanOrEqualTo: toArrow.trailingAnchor, constant: 10),
            to.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -pad),
            to.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            from.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            to.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        return bar
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: .init("source"))
        sourcesTable.addTableColumn(column)
        sourcesTable.headerView = nil
        sourcesTable.style = .sourceList
        sourcesTable.rowHeight = 26
        sourcesTable.dataSource = self
        sourcesTable.delegate = self
        sourcesTable.setAccessibilityIdentifier("import-sources")
        let scroll = NSScrollView()
        scroll.documentView = sourcesTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // Named, not bare glyphs: "+ − ⏏" said nothing until hovered.
        let add = Controls.button("Add Folder…", target: self, action: #selector(addFavorite))
        add.toolTip = "Add a folder to Favorites"
        let remove = Controls.button("Remove", target: self, action: #selector(removeFavorite))
        remove.toolTip = "Remove the selected favorite"
        let eject = NSButton(image: NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject") ?? NSImage(),
                             target: self, action: #selector(ejectSelected))
        eject.bezelStyle = .rounded
        eject.toolTip = "Eject the selected device"
        let buttons = Controls.row([add, remove, Controls.spacer(), eject], spacing: 6)

        let heading = Controls.label("SOURCE", font: Theme.Import.sectionFont, color: Theme.Color.textTertiary)
        let stack = Controls.column([heading, scroll, includeSubfolders, buttons], spacing: 8)
        stack.alignment = .leading
        includeSubfolders.target = self
        includeSubfolders.action = #selector(subfoldersChanged)
        includeSubfolders.state = .on
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for view in [scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Theme.Import.sidebarWidth - 16).isActive = true
        }
        stack.wantsLayer = true
        stack.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 10, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }

    private func buildCentre() -> NSView {
        // Filter tabs centred above the grid, each with its count.
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityIdentifier("import-filter")
        filter.controlSize = .regular
        filter.font = Theme.Import.bodyFont
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
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close viewer") ?? NSImage(),
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

        // Below the grid: tick everything or nothing, and how big.
        let checkAll = Controls.button("Check All", target: self, action: #selector(checkAll))
        let uncheckAll = Controls.button("Uncheck All", target: self, action: #selector(checkNone))
        checkAll.setAccessibilityIdentifier("import-check-all")
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.controlSize = .small
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let bar = Controls.row([checkAll, uncheckAll, Controls.spacer(),
                                Controls.label("Thumbnails", font: Theme.Font.label, color: Theme.Color.textTertiary),
                                sizeSlider], spacing: 10)

        let stack = Controls.column([tabs, viewerBox, scroll, bar], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        for view in [tabs, viewerBox, scroll, bar] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refreshHeader()
        return stack
    }

    /// Options only: how files are handled, where exactly they go, which bin.
    private func buildRightPane() -> NSView {
        methodDescription.lineBreakMode = .byWordWrapping
        methodDescription.maximumNumberOfLines = 2
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
        optimizeCheck.toolTip = "Convert each copy to DV or MPEG-2 for the SD canvas, linked to "
            + "the original and played in its place"
        optimizeCheck.target = self
        optimizeCheck.action = #selector(methodChanged)
        optimizePreset.selectItem(at: store.preferences.optimizePreset == OptimizePreset.compact.rawValue ? 1 : 0)
        optimizePreset.target = self
        optimizePreset.action = #selector(methodChanged)
        refreshBins()

        func section(_ title: String, _ views: [NSView]) -> NSStackView {
            let heading = Controls.label(title.uppercased(), font: Theme.Import.sectionFont,
                                         color: Theme.Color.textTertiary)
            let column = Controls.column([heading] + views, spacing: 8)
            column.alignment = .leading
            return column
        }
        let bin = Controls.row([Controls.label("Bin", font: Theme.Import.bodyFont, color: Theme.Color.textSecondary),
                                binPopUp], spacing: 8)
        let preset = Controls.row([Controls.label("Preset", font: Theme.Import.bodyFont,
                                                  color: Theme.Color.textSecondary), optimizePreset], spacing: 8)
        let pane = Controls.column([
            section("File handling", [skipDuplicates, optimizeCheck, preset, optimizeNote]),
            section("Destination", [subfolderCheck, subfolderField, destinationNote]),
            section("Library", [bin]),
            Controls.spacer()
        ], spacing: Theme.Import.sectionSpacing)
        pane.alignment = .leading
        let pad = Theme.Import.padding
        pane.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        pane.wantsLayer = true
        pane.layer?.backgroundColor = Theme.Color.panelFillNested.cgColor
        subfolderField.translatesAutoresizingMaskIntoConstraints = false
        subfolderField.widthAnchor.constraint(equalToConstant: Theme.Import.inspectorWidth - 2 * pad).isActive = true
        for note in [optimizeNote, destinationNote] {
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 3
            note.preferredMaxLayoutWidth = Theme.Import.inspectorWidth - 2 * pad
        }
        return pane
    }

    /// The count and size on the left, what Import will do in the middle, Import on the
    /// right — one place to finish.
    private func buildFooter() -> NSView {
        countsLabel.alignment = .left
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        importButton.bezelStyle = .rounded
        importButton.controlSize = .large
        importButton.keyEquivalent = "\r"          // Return imports
        importButton.bezelColor = Theme.Color.accent   // the one primary action, lit even when the window is not key
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.setAccessibilityIdentifier("import-go")
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let row = Controls.row([countsLabel, Controls.spacer(), summaryLabel, importButton], spacing: 16)
        let pad = Theme.Import.padding
        row.edgeInsets = NSEdgeInsets(top: 0, left: pad, bottom: 0, right: pad)
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.bar.cgColor
        return row
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
        destinationButton.isEnabled = usesDestination
        destinationName.textColor = usesDestination ? Theme.Color.textPrimary : Theme.Color.textTertiary
        destinationIcon.contentTintColor = usesDestination ? Theme.Color.accent : Theme.Color.textTertiary
        subfolderCheck.isEnabled = usesDestination
        subfolderField.isEnabled = usesDestination && subfolderCheck.state == .on
        destinationNote.stringValue = usesDestination ? ""
            : "Not used — Add leaves the files where they are."
        if !allowsMove { destinationNote.stringValue += (destinationNote.stringValue.isEmpty ? "" : " ")
            + "Move is off: this source is read-only or removable." }
        destinationNote.isHidden = destinationNote.stringValue.isEmpty
        // Optimize only with COPY (proposal §5: Add and Move grey it out).
        optimizeCheck.isEnabled = method == .copy
        optimizePreset.isEnabled = method == .copy && optimizeCheck.state == .on
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

    /// The folder a Move or Copy goes to.
    private func showDestination() {
        destinationName.stringValue = destination.lastPathComponent
        destinationPath.stringValue = destination.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        destinationButton.toolTip = destination.path
    }

    @objc private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should moved or copied clips go?"
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        showDestination()
        updateImportButton()
    }

    /// Points Move/Copy somewhere else — for self-QA (scratch folders only).
    func setDestinationForChecks(_ url: URL) {
        destination = url
        showDestination()
        updateImportButton()
    }

    /// Whether the destination controls are live — for self-QA.
    var destinationEnabled: Bool { destinationButton.isEnabled }
    var moveEnabled: Bool { methodControl.isEnabled(forSegment: 1) }
    /// The summary sentence and the header — for self-QA.
    var summaryForChecks: String { summaryLabel.stringValue }
    var headerForChecks: (title: String, counts: String) { (titleLabel.stringValue, countsLabel.stringValue) }
    var isViewerOpen: Bool { !viewerBox.isHidden }

    // MARK: - Header, filter counts, the selection menu

    /// The folder's name and path, and what is in it — or why there is nothing.
    private func refreshHeader() {
        guard let source = currentSource else {
            titleLabel.stringValue = "Choose a source"
            pathLabel.stringValue = "a folder or device on the left"
            countsLabel.stringValue = ""
            emptyState.stringValue = "Choose a folder or device on the left."
            emptyState.isHidden = false
            return
        }
        titleLabel.stringValue = source.title
        pathLabel.stringValue = source.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
            ? SetupChoices.optimizePreset(at: optimizePreset.indexOfSelectedItem) : nil
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

/// A tile, Lightroom's way: a cell with the checkbox in its corner, the picture
/// (the library's hover-scrub, I/O marks and all), the name and size under it, and
/// solid pills for what matters — wedge-ready, a shape that does not fit, already in
/// the library. Checked cells are lit; unchecked ones step back.
final class ImportTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("import-tile")

    private let picture = HoverScrubView()
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = Controls.label("", font: Theme.Import.bodyFont, color: Theme.Color.textPrimary)
    private let size = Controls.label("", font: Theme.Font.label, color: Theme.Color.textTertiary)
    private let pills = NSStackView()
    private var url: URL?
    private var badgeParts: [String] = []
    var onChecked: ((Bool) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onMarks: ((URL, ImportModeView.Marks) -> Void)?

    override func loadView() {
        let tile = ImportTileView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = Theme.Import.tileCornerRadius
        tile.layer?.borderWidth = 1
        tile.onDoubleClick = { [weak self] in if let url = self?.url { self?.onOpen?(url) } }
        picture.onMarksChanged = { [weak self] inPoint, outPoint in
            if let url = self?.url { self?.onMarks?(url, (inPoint, outPoint)) }
        }
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 3
        picture.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        check.target = self
        check.action = #selector(checkChanged)
        pills.orientation = .horizontal
        pills.spacing = Theme.Import.pillSpacing
        let inset: CGFloat = 6
        for view in [check, picture, name, size, pills] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.topAnchor.constraint(equalTo: tile.topAnchor, constant: 4),
            check.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: inset),
            pills.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            pills.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -inset),
            pills.leadingAnchor.constraint(greaterThanOrEqualTo: check.trailingAnchor, constant: 4),
            picture.topAnchor.constraint(equalTo: check.bottomAnchor, constant: 4),
            picture.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: inset),
            picture.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -inset),
            picture.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -4),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: inset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: size.leadingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -5),
            size.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -inset),
            size.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor)
        ])
        size.setContentCompressionResistancePriority(.required, for: .horizontal)
        view = tile
    }

    func configure(_ entry: ImportEntry) {
        url = entry.url
        picture.item = ShellController.libraryItem(for: entry.url)
        check.state = entry.isChecked ? .on : .off
        name.stringValue = entry.url.lastPathComponent
        size.stringValue = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        badgeParts = [entry.isDuplicate ? "DUP" : nil, entry.wedge, entry.mismatch].compactMap { $0 }
        pills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let wedge = entry.wedge { pills.addArrangedSubview(Self.pill(wedge, Theme.Import.wedgePill)) }
        if let mismatch = entry.mismatch {
            // The amber says "does not fit"; a ⚠ glyph beside capitals only sat on its
            // own baseline. The tooltip says it in words.
            pills.addArrangedSubview(Self.pill(mismatch.replacingOccurrences(of: "⚠", with: ""), Theme.Import.mismatchPill))
        }
        if entry.isDuplicate { pills.addArrangedSubview(Self.pill("IN LIBRARY", Theme.Import.duplicatePill)) }
        view.toolTip = [entry.isDuplicate ? "Already in the library." : nil,
                        entry.wedge.map { "\($0): the bitstream effects work on it." },
                        entry.mismatch.map { _ in "Not the canvas's shape — it will be fitted." }]
            .compactMap { $0 }.joined(separator: " ").nilIfEmpty
        applyLook()
    }

    /// Lit when checked; unchecked cells (and clips already in the library) step back.
    private func applyLook() {
        let checked = check.state == .on
        view.layer?.backgroundColor = (checked ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.04)).cgColor
        view.layer?.borderColor = (checked ? Theme.Color.accent.withAlphaComponent(0.8) : NSColor.clear).cgColor
        picture.alphaValue = checked ? 1 : 0.55
        name.textColor = checked ? Theme.Color.textPrimary : Theme.Color.textSecondary
    }

    private static func pill(_ text: String, _ colour: NSColor) -> NSView {
        ImportPill(text: text, colour: colour)
    }

    func showMarks(_ marks: ImportModeView.Marks) {
        picture.setInOut(inPoint: marks.inPoint, outPoint: marks.outPoint)
    }

    /// The picture — for self-QA (it takes I and O while hovered).
    var pictureForChecks: HoverScrubView { picture }

    /// The badge text — for self-QA.
    var badgeText: String { badgeParts.joined(separator: " ") }

    @objc private func checkChanged() {
        applyLook()
        onChecked?(check.state == .on)
    }
}

/// A codec / shape / library pill, drawn rather than made of a text field.
///
/// It was an NSTextField with a layer background and a fixed height: a text field
/// never centres its text vertically, so every word rode against the pill's top edge;
/// its cell's own insets made the sides uneven; its background filled the whole frame,
/// so neighbouring pills touched; and the colours were black bold text on saturated
/// slabs. Drawn here instead: text centred on its cap height, the same padding either
/// side, and a tint — coloured text and hairline over a faint wash of the colour.
final class ImportPill: NSView {
    private let text: NSAttributedString
    private let colour: NSColor

    init(text: String, colour: NSColor) {
        self.colour = colour
        self.text = NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.Import.pillFont,
            .foregroundColor: colour,
            .kern: Theme.Import.pillTracking
        ])
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(text.size().width) + 2 * Theme.Import.pillPaddingX, height: Theme.Import.pillHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: body, xRadius: Theme.Import.pillCornerRadius,
                                 yRadius: Theme.Import.pillCornerRadius)
        colour.withAlphaComponent(0.16).setFill()
        shape.fill()
        colour.withAlphaComponent(0.45).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // Centre the CAPITALS, not the line box: capitals have no descenders, so a
        // line-box centre sits them visibly high.
        let font = Theme.Import.pillFont
        let size = text.size()
        let baseline = bounds.midY - font.capHeight / 2
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: baseline + font.descender))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
