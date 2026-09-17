//
//  LibraryPanelBody.swift — the two sub-mix libraries and the central asset browser.
//
//  Purpose : SPEC 14.2's thumbnail grids. The sub-mix libraries hold the working set
//            staged for one side; the asset browser is the global, tabbed library.
//            Both use `NSCollectionView` as SPEC 14.3 requires.
//  Inputs  : `LibraryItem`s (name plus a type badge).
//  Outputs : a scrolling grid of labelled thumbnails.
//  Connects: Controls, Theme; later, the samples manifest and the render graph.
//  Extend  : drag-to-load and real thumbnails arrive with the source modules. The
//            grid itself should not need changing.
//

import AppKit
import VideoboyCore

/// One entry in a library grid.
struct LibraryItem {
    /// Display name, e.g. "bars.dv".
    let name: String
    /// Short type badge: DV, MOV, MPG, GEN, SVG, SCR, IP, CAP, EMU, IMG.
    let badge: String
    /// False for item kinds whose source module is not built yet.
    let isAvailable: Bool
    /// The file on disk, for items that have one. Nil for generators and for the
    /// kinds that are advertised but not built.
    let url: URL?

    init(name: String, badge: String, isAvailable: Bool, url: URL? = nil) {
        self.name = name
        self.badge = badge
        self.isAvailable = isAvailable
        self.url = url
    }
}

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

/// The view for one library item: a fixed-size thumbnail with a badge and a caption.
///
/// Every item is exactly the same size. Items that size themselves to their caption
/// read as clutter however neatly they are spaced, and a grid whose cells differ is
/// not really a grid.
///
/// Hovering scrubs the clip, as FCP does: running the pointer across a thumbnail
/// tells you what a file IS far faster than reading its name. In and out points are
/// set with I and O while hovering, and are drawn on the strip beneath.
final class LibraryItemView: NSView {

    let item: LibraryItem

    /// Called on double-click, with the clip and whatever in/out range is marked.
    var onOpen: ((LibraryItem, ClosedRange<Double>?) -> Void)?

    private let thumbnail = HoverScrubView()

    init(item: LibraryItem) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        thumbnail.item = item
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        thumbnail.layer?.cornerRadius = 2
        thumbnail.layer?.borderWidth = Theme.Metrics.hairline
        thumbnail.layer?.borderColor = Theme.Color.panelBorder.cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        // holdsWidth: the badge is two or three characters naming what the asset IS.
        // Left to truncate it becomes "…", which names nothing — and a two-character
        // badge truncating while a three-character one survives looks like a bug in
        // the thumbnail rather than a layout squeeze.
        let badge = Controls.monoLabel(
            item.badge,
            color: item.isAvailable ? Theme.Color.accent : Theme.Color.textTertiary,
            holdsWidth: true
        )
        badge.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.addSubview(badge)

        let caption = Controls.label(
            item.name, font: Theme.Font.tinyLabel,
            color: item.isAvailable ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.lineBreakMode = .byTruncatingMiddle
        caption.alignment = .center
        // The caption must never widen the cell — a long filename truncates instead.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(thumbnail)
        addSubview(caption)

        if item.url != nil {
            toolTip = "Double-click to load · drag to a source · I and O set in and out"
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailSide),

            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailImageHeight),

            badge.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 2),
            badge.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 3),

            caption.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailCaptionHeight),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func mouseDown(with event: NSEvent) {
        guard item.isAvailable else { return }
        if event.clickCount >= 2 {
            onOpen?(item, thumbnail.markedRange)
            pressOrigin = nil
            return
        }
        // Remember where the press began and wait. A press is not yet a drag, and a
        // drag is not yet a click.
        pressOrigin = item.url == nil ? nil : event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, let url = item.url else { return }
        let travelled = hypot(
            event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
        guard travelled >= Self.dragThreshold else { return }

        // AppKit delivers mouseDragged to whichever view took the mouseDown, so this
        // is the idiomatic place to start a drag. The previous version pulled events
        // out of the window itself in a loop inside mouseDown, which works only as
        // long as nothing else is reading the queue — and is a strange way to ask a
        // question AppKit is already answering.
        pressOrigin = nil
        beginDrag(url: url, from: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
    }

    /// Where the current press started, or nil when there is no press in progress.
    private var pressOrigin: NSPoint?

    /// How far the pointer must move before a press counts as a drag. Three points is
    /// the usual allowance for a hand that is not quite still.
    private static let dragThreshold: CGFloat = 3

    /// Drags the clip's file, so it can be dropped on a source panel — or anywhere
    /// else that takes a file, which is the point of using the standard type.
    /// Set by the self-QA to observe that a drag was started, without a real mouse.
    ///
    /// Drag and drop is the one gesture the offscreen harness cannot perform, so the
    /// alternative is having no check at all on the half that kept breaking.
    static var onDragStartedForChecks: ((URL) -> Void)?

    private func beginDrag(url: URL, from event: NSEvent) {
        Self.onDragStartedForChecks?(url)
        let dragItem = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: url))
        dragItem.setDraggingFrame(thumbnail.frame, contents: thumbnailSnapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// Every library cell beneath a view, for the self-QA.
    static func all(in view: NSView) -> [LibraryItemView] {
        var found: [LibraryItemView] = []
        if let cell = view as? LibraryItemView { found.append(cell) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    /// What the library puts on the pasteboard for a clip.
    ///
    /// One place, so what is written and what the drop targets read cannot drift
    /// apart — which is the only way a drag silently does nothing.
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Both spellings: `.fileURL` is what a modern reader asks for, and the plain
        // string is what some targets still look for. Writing one and reading the
        // other is exactly how a drag ends up doing nothing at all.
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        return item
    }

    /// A picture of the thumbnail, so what is dragged looks like what was grabbed.
    private func thumbnailSnapshot() -> NSImage? {
        guard let representation = thumbnail.bitmapImageRepForCachingDisplay(in: thumbnail.bounds)
        else { return nil }
        thumbnail.cacheDisplay(in: thumbnail.bounds, to: representation)
        let image = NSImage(size: thumbnail.bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

extension LibraryItemView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy, not move: dragging a clip out of the library must never be a way to
        // lose the file.
        .copy
    }
}

/// The picture area of a library item, which scrubs under the pointer.
///
/// Split from `LibraryItemView` so the drawing and the mouse tracking are not tangled
/// with the cell's layout. This view owns the playhead, the in/out points and the
/// decoded frame; the cell owns the badge, the caption and the drag.
final class HoverScrubView: NSView {

    var item: LibraryItem?

    /// 0...1 under the pointer, or nil when not hovering.
    private var scrubPosition: Double?
    /// In and out points, 0...1, as set with I and O.
    private var inPoint: Double?
    private var outPoint: Double?

    private var frameImage: NSImage?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateScrub(with: event)
    }

    /// Hands the press to the cell, which owns opening and dragging.
    ///
    /// Explicitly, rather than leaving it to NSResponder's default forwarding. This
    /// view sits on top of the whole thumbnail, so it is what a press actually lands
    /// on, and "the default probably forwards it" is not a thing to rest drag and
    /// drop on.
    override func mouseDown(with event: NSEvent) {
        guard let cell = superview as? LibraryItemView else {
            super.mouseDown(with: event)
            return
        }
        cell.mouseDown(with: event)
    }

    // The rest of the gesture has to follow the press. Forwarding only mouseDown
    // would leave the cell waiting for a drag that AppKit is delivering here.
    override func mouseDragged(with event: NSEvent) {
        (superview as? LibraryItemView)?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        (superview as? LibraryItemView)?.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateScrub(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        // Back to the poster frame, so a thumbnail at rest always shows the same
        // picture rather than wherever the pointer happened to leave it.
        scrub(to: nil)
    }

    private func updateScrub(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        scrub(to: min(max(Double(x / bounds.width), 0), 1))
    }

    /// Moves the playhead to a position, or clears it with nil.
    ///
    /// The mouse handlers go through here, and so does the self-QA render — there is
    /// no way to synthesise a hover offscreen, and a check that set the playhead
    /// field directly would prove the drawing works and nothing about whether
    /// hovering ever reaches it.
    func scrub(to position: Double?) {
        guard let item, item.url != nil else { return }
        scrubPosition = position
        loadFrame(at: position ?? 0)
        needsDisplay = true
    }

    /// The in and out points, for the self-QA render and for loading a trimmed clip.
    func setInOut(inPoint: Double?, outPoint: Double?) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        needsDisplay = true
    }

    /// The marked range, or nil when the whole clip is wanted.
    ///
    /// One mark counts: marking only an in point means "from here to the end", which
    /// is what every editor does and what anyone setting a single mark expects.
    var markedRange: ClosedRange<Double>? {
        guard inPoint != nil || outPoint != nil else { return nil }
        return (inPoint ?? 0)...(outPoint ?? 1)
    }

    /// True once a frame has actually been decoded into this thumbnail.
    var hasDecodedFrame: Bool { frameImage != nil }

    /// The picture area of every item beneath a view, for the self-QA render.
    static func all(in view: NSView) -> [HoverScrubView] {
        var found: [HoverScrubView] = []
        if let hover = view as? HoverScrubView { found.append(hover) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    /// Decodes and keeps the frame for a position.
    ///
    /// `ClipThumbnails` quantises and caches, so following the pointer asks for the
    /// same dozen frames over and over and decodes each only once.
    private func loadFrame(at position: Double) {
        guard let url = item?.url else { return }
        guard let buffer = ClipThumbnails.shared.frame(for: url, at: position) else { return }
        guard let cgImage = buffer.makeCGImage() else { return }
        frameImage = NSImage(
            cgImage: cgImage, size: NSSize(width: buffer.width, height: buffer.height))
    }

    override func keyDown(with event: NSEvent) {
        // In and out while hovering, as FCP does. Only meaningful with a position,
        // which is to say only while the pointer is over the strip.
        guard let position = scrubPosition else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i":
            inPoint = position
            // An in point after the out point is not a range; the later one gives way
            // rather than the edit being silently refused.
            if let out = outPoint, out < position { outPoint = nil }
            Log.info(.app, "in point at \(String(format: "%.2f", position)) on \(item?.name ?? "?")")
        case "o":
            outPoint = position
            if let into = inPoint, into > position { inPoint = nil }
            Log.info(.app, "out point at \(String(format: "%.2f", position)) on \(item?.name ?? "?")")
        case "x":
            inPoint = nil
            outPoint = nil
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The decoded frame, or the empty-preview colour when there is none.
        if let frameImage {
            frameImage.draw(in: bounds)
        } else {
            Theme.Color.previewEmpty.setFill()
            bounds.fill()
        }

        guard item?.url != nil else { return }

        // The in/out range, dimmed outside and bracketed at the edges — FCP's
        // reading, where what is EXCLUDED is what gets shaded.
        if inPoint != nil || outPoint != nil {
            let start = (inPoint ?? 0) * Double(bounds.width)
            let end = (outPoint ?? 1) * Double(bounds.width)
            Theme.Color.previewEmpty.withAlphaComponent(0.66).setFill()
            NSRect(x: 0, y: 0, width: start, height: bounds.height).fill()
            NSRect(x: end, y: 0, width: bounds.width - end, height: bounds.height).fill()

            Theme.Color.accent.setFill()
            let bracket: CGFloat = 2
            if inPoint != nil {
                NSRect(x: start, y: 0, width: bracket, height: bounds.height).fill()
            }
            if outPoint != nil {
                NSRect(x: end - bracket, y: 0, width: bracket, height: bounds.height).fill()
            }
        }

        // The playhead under the pointer.
        if let scrubPosition {
            Theme.Color.textPrimary.setFill()
            NSRect(x: scrubPosition * Double(bounds.width) - 0.5, y: 0,
                   width: 1, height: bounds.height).fill()
        }
    }

    /// Shows the poster frame once the view has a size to draw into.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, frameImage == nil else { return }
        loadFrame(at: 0)
        needsDisplay = true
    }
}

/// Which kind of asset a browser tab shows.
enum AssetTab: String, CaseIterable {
    case sources
    case generators
    case graphics
    case clips
    case images

    var displayName: String {
        switch self {
        case .sources: "Sources"
        case .generators: "Generators"
        case .graphics: "Graphics"
        case .clips: "Clips"
        case .images: "Images"
        }
    }

    /// What to say when a tab has nothing in it, so an empty grid is never just a
    /// blank rectangle the user has to guess about.
    var emptyMessage: String {
        switch self {
        case .sources: "No media in samples/. Drop files there and re-run scripts/make-fixtures.sh."
        case .generators: "No generators available."
        case .graphics: "SVG and vector sources are not built yet (SPEC §17)."
        case .clips: "Clip bins are not built yet."
        case .images: "Still-image sources are not built yet."
        }
    }
}

/// A library grid with a toolbar above it.
final class LibraryPanelBody: NSView {

    private let grid = NSGridView()

    /// Grids by tab, so switching a tab swaps content rather than rebuilding it.
    private var gridsByTab: [AssetTab: NSView] = [:]
    /// What the Sources tab shows. Held because a drop adds to it.
    private var sourceItems: [LibraryItem] = []
    /// The scrolling document, so a rebuilt grid goes back in the same place.
    private var documentView: LibraryDropView?
    private var emptyLabelsByTab: [AssetTab: NSTextField] = [:]
    private var currentTab: AssetTab = .sources
    private let columns: Int

    /// Called when an item is double-clicked: the clip, its channel, and any marks.
    var onItemOpened: ((LibraryItem, String, ClosedRange<Double>?) -> Void)?

    /// Where double-clicked clips go, and which of the pair is next.
    let destination = ChannelDestination()

    /// Called when files are dropped onto this library, so the app can add them.
    var onFilesDropped: (([URL]) -> Void)?

    /// Highlighted while a drop is hovering over the grid.
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            layer?.borderWidth = isDropTarget ? 2 : 0
            layer?.borderColor = Theme.Color.accent.cgColor
            layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        }
    }

    /// The A/B / C/D toggle, so its title can show which channel is next.
    private var destinationControl: NSSegmentedControl?

    /// - Parameters:
    ///   - items: what the Sources tab shows.
    ///   - columns: 3 for the sub-mix libraries, 6 for the central browser.
    ///   - showsTabs: true for the asset browser, which is tabbed by asset kind.
    init(items: [LibraryItem], columns: Int, showsTabs: Bool) {
        self.columns = columns
        super.init(frame: .zero)
        wantsLayer = true

        // A library is where you COLLECT things, so it has to accept them being put
        // there. Dropping a file on a library was the obvious gesture and did nothing
        // at all, which reads as the app being broken rather than as a missing
        // feature.
        registerForDraggedTypes([.fileURL])

        // The tabbed browser carries five tabs, a destination toggle, a search field
        // and Import. That does not fit one row at this panel's width — the tabs were
        // being clipped off the left edge, which is worse than truncation because
        // there is no ellipsis to tell you something is missing. So the browser gets
        // two rows: what you are looking at on top, what you can do with it beneath.
        // The cost is one partial row of thumbnails, which is the cheaper loss.
        var topRow: [NSView] = []
        var bottomRow: [NSView] = []
        var tabControl: NSSegmentedControl?

        if showsTabs {
            let tabs = Controls.segmented(
                AssetTab.allCases.map(\.displayName), selected: 0,
                target: self, action: #selector(tabChanged(_:)))
            tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
            tabControl = tabs
            topRow.append(tabs)
            topRow.append(Controls.spacer())
        } else {
            bottomRow.append(Controls.popUp(["Page 1"], enabled: false))
        }

        // Where a double-clicked clip goes. Present on every library: the sub-mix
        // libraries default to their own side, and the browser starts on A/B.
        let pairs = ChannelDestination.Pair.allCases
        let destinationToggle = Controls.segmented(
            pairs.map(\.displayName), selected: 0,
            target: self, action: #selector(destinationChanged(_:)))
        destinationToggle.toolTip = "Where a double-clicked clip is loaded"
        destinationToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        destinationControl = destinationToggle
        bottomRow.append(destinationToggle)

        let search = Controls.searchField(
            placeholder: showsTabs ? "Search library…" : "Search…", enabled: showsTabs)
        search.target = self
        search.action = #selector(searchChanged(_:))
        // The search field is the one thing in this row that can usefully give way:
        // it shrinks to its glyph and still reads as a search field, which is more
        // than a truncated tab or a truncated button can say for themselves.
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

        let headerRow: NSView
        if topRow.isEmpty {
            headerRow = Controls.row(bottomRow, spacing: 4)
        } else {
            headerRow = Controls.column([
                Controls.row(topRow, spacing: 4),
                Controls.row(bottomRow, spacing: 4)
            ], spacing: 3)
        }
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)

        // A flipped document view keeps the grid anchored to the top of the panel.
        let document = LibraryDropView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.onFilesDropped = { [weak self] urls in self?.onFilesDropped?(urls) }
        documentView = document
        sourceItems = items

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Build every tab's grid up front and show one. The sets are small and this
        // makes switching instant, which is what a tab strip implies.
        let tabs: [AssetTab] = showsTabs ? AssetTab.allCases : [.sources]
        for tab in tabs {
            let grid = makeGrid(for: contents(of: tab, sources: items))
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.isHidden = tab != currentTab
            document.addSubview(grid)
            gridsByTab[tab] = grid

            let empty = Controls.label(
                tab.emptyMessage, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.isHidden = tab != currentTab || !contents(of: tab, sources: items).isEmpty
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 3
            document.addSubview(empty)
            emptyLabelsByTab[tab] = empty

            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: document.topAnchor),
                grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
                empty.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
                empty.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
                empty.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4)
            ])
        }

        // The document's height follows whichever grid is showing.
        if let first = gridsByTab[currentTab] {
            documentHeight = document.heightAnchor.constraint(
                greaterThanOrEqualTo: first.heightAnchor)
            documentHeight?.isActive = true
        }

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor)
        ])

        _ = tabControl
    }

    private var documentHeight: NSLayoutConstraint?

    /// What each tab contains.
    private func contents(of tab: AssetTab, sources: [LibraryItem]) -> [LibraryItem] {
        switch tab {
        case .sources:
            return sources
        case .generators:
            // Every generator is real and assignable, so they are all available.
            return GeneratorKind.allCases.map {
                LibraryItem(name: $0.displayName, badge: "GEN", isAvailable: true)
            }
        case .graphics, .clips, .images:
            // Empty on purpose; the tab says why rather than showing a blank box.
            return []
        }
    }

    /// Builds one uniform grid of items.
    private func makeGrid(for items: [LibraryItem]) -> NSView {
        let itemsStack = NSStackView()
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = Theme.Metrics.thumbnailGap

        var row: [NSView] = []
        for item in items {
            let view = LibraryItemView(item: item)
            view.onOpen = { [weak self] item, range in
                guard let self else { return }
                let channel = self.destination.takeNextChannel()
                self.onItemOpened?(item, channel, range)
                self.updateDestinationTitles()
            }
            row.append(view)
            if row.count == columns {
                itemsStack.addArrangedSubview(Controls.row(row, spacing: Theme.Metrics.thumbnailGap))
                row = []
            }
        }
        if !row.isEmpty {
            itemsStack.addArrangedSubview(
                Controls.row(row + [Controls.spacer()], spacing: Theme.Metrics.thumbnailGap))
        }
        return itemsStack
    }

    // MARK: - Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedURLs(from: sender).isEmpty else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let urls = droppedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    /// Every file URL on the pasteboard. A library takes several at once, because
    /// dropping a folderful is the normal way to fill one.
    private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
        }
        return SourcePanelBody.fileURL(from: pasteboard).map { [$0] } ?? []
    }

    /// Replaces the Sources grid in place, keeping its position and constraints.
    private func rebuildSourcesGrid() {
        guard let document = documentView else { return }
        let old = gridsByTab[.sources]
        old?.removeFromSuperview()

        let grid = makeGrid(for: sourceItems)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.isHidden = currentTab != .sources
        document.addSubview(grid)
        gridsByTab[.sources] = grid
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor)
        ])
        emptyLabelsByTab[.sources]?.isHidden = !sourceItems.isEmpty || currentTab != .sources

        if currentTab == .sources {
            documentHeight?.isActive = false
            documentHeight = document.heightAnchor.constraint(
                greaterThanOrEqualTo: grid.heightAnchor)
            documentHeight?.isActive = true
        }
        needsLayout = true
    }

    /// Adds items to the Sources tab and rebuilds that grid.
    func addItems(_ newItems: [LibraryItem]) {
        guard !newItems.isEmpty else { return }
        // Already-present files are skipped rather than duplicated: dropping the same
        // folder twice should leave the library as it was, not doubled.
        let existing = Set(sourceItems.compactMap { $0.url?.path })
        let additions = newItems.filter { url in
            guard let path = url.url?.path else { return true }
            return !existing.contains(path)
        }
        guard !additions.isEmpty else { return }
        sourceItems.append(contentsOf: additions)
        rebuildSourcesGrid()
        Log.info(.app, "added \(additions.count) item(s) to a library")
    }

    @objc private func destinationChanged(_ sender: NSSegmentedControl) {
        let pairs = ChannelDestination.Pair.allCases
        guard pairs.indices.contains(sender.selectedSegment) else { return }
        destination.pair = pairs[sender.selectedSegment]
        updateDestinationTitles()
    }

    /// Marks which channel the next double-click will fill.
    ///
    /// The segment shows "A/B ▸ B" rather than just "A/B": the auto-advance is the
    /// whole point of the control, and a toggle that silently alternates would be a
    /// surprise every second clip.
    private func updateDestinationTitles() {
        guard let control = destinationControl else { return }
        for (index, pair) in ChannelDestination.Pair.allCases.enumerated() {
            let isCurrent = pair == destination.pair
            control.setLabel(
                isCurrent ? "\(pair.displayName)·\(destination.nextChannel)" : pair.displayName,
                forSegment: index)
        }
    }

    /// Sets which pair this library fills, for the sub-mix libraries that own a side.
    func setDestinationPair(_ pair: ChannelDestination.Pair) {
        destination.pair = pair
        destinationControl?.selectedSegment =
            ChannelDestination.Pair.allCases.firstIndex(of: pair) ?? 0
        updateDestinationTitles()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < AssetTab.allCases.count else { return }
        let tab = AssetTab.allCases[index]
        guard tab != currentTab else { return }

        gridsByTab[currentTab]?.isHidden = true
        emptyLabelsByTab[currentTab]?.isHidden = true
        currentTab = tab

        let grid = gridsByTab[tab]
        grid?.isHidden = false
        // The empty message shows only when there is genuinely nothing to show.
        let isEmpty = (grid as? NSStackView)?.arrangedSubviews.isEmpty ?? true
        emptyLabelsByTab[tab]?.isHidden = !isEmpty

        // Re-point the document's height at whichever grid is now visible.
        documentHeight?.isActive = false
        if let grid {
            documentHeight = grid.superview?.heightAnchor.constraint(
                greaterThanOrEqualTo: grid.heightAnchor)
            documentHeight?.isActive = true
        }
        Log.info(.app, "asset browser showing \(tab.displayName)")
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        // Filtering is not built; saying so beats silently ignoring what was typed.
        guard !sender.stringValue.isEmpty else { return }
        Log.info(.app, "library search is not built yet (typed: \(sender.stringValue))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}

/// The library's scrolling document, which also takes drops.
///
/// The panel body beneath it is registered too, and AppKit walks up from the view
/// under the pointer to find a registered one — so in principle this is redundant.
/// In practice the grid fills the panel, a drop landing on it is the ordinary case,
/// and relying on that walk is the kind of assumption that leaves a feature quietly
/// not working. Registering the view people actually aim at costs one class.
final class LibraryDropView: FlippedView {

    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        onFilesDropped?(dropped)
        return true
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        if let found = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !found.isEmpty {
            return found
        }
        return SourcePanelBody.fileURL(from: pasteboard).map { [$0] } ?? []
    }
}
