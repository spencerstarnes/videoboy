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

extension NSPasteboard.PasteboardType {
    /// The in and out points a dragged clip carries, as "lower,upper".
    ///
    /// Private to this app: a clip dragged to the Finder is still just a file, and a
    /// file dragged in from the Finder simply has no marks.
    static let videoboyClipRange = NSPasteboard.PasteboardType("com.videoboy.clip-range")
}
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

    /// The `ConfiguredSource.id` this item represents, for a Sources-tab tile.
    /// Nil for every other kind of item — a clip, a generator, the emulator's own
    /// stale placeholder before this type existed.
    var configuredSourceID: String?

    /// Which bin this item sits in. Nil means the ungrouped set at the top.
    ///
    /// A plain string rather than a bin object: bins here are a way of arranging a
    /// grid, not a thing with an identity of its own, and a name is the whole of what
    /// distinguishes one from another.
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
        case "GEN": "Generator"
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

    init(
        name: String, badge: String, isAvailable: Bool,
        url: URL? = nil, bin: String? = nil, duration: Double? = nil,
        configuredSourceID: String? = nil
    ) {
        self.name = name
        self.badge = badge
        self.isAvailable = isAvailable
        self.url = url
        self.bin = bin
        self.duration = duration
        self.configuredSourceID = configuredSourceID
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

    /// Every channel, in the order the focus control lists them.
    static let allChannels = ["A", "B", "C", "D"]

    /// Points the focus straight at one channel.
    ///
    /// The control offers all four rather than two pairs: picking the pair and then
    /// letting it alternate meant the channel you actually wanted was sometimes one
    /// load away, which is a strange thing to have to wait for. Choosing the pair is
    /// still implied — it follows from the channel.
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

    /// Called from the context menu: (clip, channel, playNext). `playNext` puts it at
    /// the FRONT of that channel's queue rather than the end.
    var onQueue: ((LibraryItem, String, Bool) -> Void)?

    /// Which channels this cell offers to queue onto — ["A", "B"] in the A/B library,
    /// ["C", "D"] in C/D. Empty means no queue menu at all, which is right for the
    /// asset browser: it belongs to no bus, so there is no obvious channel to mean.
    var queueChannels: [String] = []

    private let thumbnail = HoverScrubView()

    /// A right-click menu offering this clip to either channel of the bus.
    ///
    /// Built fresh each time rather than kept on the view, because the channel list
    /// can change with the library's bus and a stale menu would queue onto the wrong
    /// source — which is the sort of mistake you only notice once it is on air.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !queueChannels.isEmpty, item.url != nil else { return nil }

        let menu = NSMenu()

        // Bins first — the menu is mostly about where this clip LIVES, and the queue
        // entries below are about where it is going next.
        if let owner = binOwner {
            let bins = owner.binNames
            if !bins.isEmpty || item.bin != nil {
                for bin in bins {
                    let move = NSMenuItem(
                        title: "Move to \(bin)", action: #selector(moveToBin(_:)), keyEquivalent: "")
                    move.target = self
                    move.representedObject = bin
                    move.state = item.bin == bin ? .on : .off
                    menu.addItem(move)
                }
                if item.bin != nil {
                    let out = NSMenuItem(
                        title: "Remove from bin", action: #selector(moveToBin(_:)), keyEquivalent: "")
                    out.target = self
                    menu.addItem(out)
                }
                menu.addItem(.separator())
            }
        }

        for channel in queueChannels {
            let add = NSMenuItem(
                title: "Add to \(channel)", action: #selector(queueLast(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = channel
            menu.addItem(add)
        }
        menu.addItem(.separator())
        for channel in queueChannels {
            let next = NSMenuItem(
                title: "Play Next on \(channel)", action: #selector(queueNext(_:)), keyEquivalent: "")
            next.target = self
            next.representedObject = channel
            menu.addItem(next)
        }
        return menu
    }

    /// The library this cell belongs to, so its menu can list that library's bins.
    weak var binOwner: LibraryPanelBody?

    @objc private func moveToBin(_ sender: NSMenuItem) {
        binOwner?.moveItem(named: item.name, toBin: sender.representedObject as? String)
    }

    @objc private func queueLast(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? String else { return }
        onQueue?(item, channel, false)
    }

    @objc private func queueNext(_ sender: NSMenuItem) {
        guard let channel = sender.representedObject as? String else { return }
        onQueue?(item, channel, true)
    }

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
        if let observer = Self.onDragStartedForChecks {
            // Under the self-QA: record the drag and stop there. A real session
            // waits for a PHYSICAL mouse-up, and with nobody at the machine it never
            // comes — unattended `selfqa ui` runs hung for hours inside AppKit's drag
            // manager. What the check needs to know is that the drag STARTS; what it
            // carries is checked separately, off the pasteboard.
            observer(url)
            return
        }
        let dragItem = NSDraggingItem(
            pasteboardWriter: Self.pasteboardItem(for: url, range: thumbnail.markedRange))
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
    static func pasteboardItem(for url: URL, range: ClosedRange<Double>? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Both spellings: `.fileURL` is what a modern reader asks for, and the plain
        // string is what some targets still look for. Writing one and reading the
        // other is exactly how a drag ends up doing nothing at all.
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        // The MARKS travel with the clip. Without this a dragged clip arrived with no
        // in or out point and played the whole file, while the same clip opened by
        // double-click honoured them — so the marks looked broken rather than
        // unsupported on one of the two ways of loading.
        if let range {
            item.setString("\(range.lowerBound),\(range.upperBound)", forType: .videoboyClipRange)
        }
        return item
    }

    /// Reads the marks a dragged clip was carrying, if it was carrying any.
    static func markedRange(from pasteboard: NSPasteboard) -> ClosedRange<Double>? {
        guard let raw = pasteboard.string(forType: .videoboyClipRange) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, parts[0] <= parts[1] else { return nil }
        return parts[0]...parts[1]
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
    /// The hover position, exposed so a check can tell "the keys did nothing" from
    /// "the pointer was never considered to be over the strip".
    var scrubPositionForChecks: Double? { scrubPosition }

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
        case .clips: "No clips yet. Drop clips or folders here, or press + to add."
        case .images: "Still-image sources are not built yet."
        case .emu: "No emulated machines are set up."
        }
    }
}

/// A library grid with a toolbar above it.
final class LibraryPanelBody: NSView {

    private let grid = NSGridView()

    /// Grids by tab, so switching a tab swaps content rather than rebuilding it.
    private var gridsByTab: [AssetTab: NSView] = [:]
    /// What the Sources tab shows. Held because a drop adds to it.
    /// The ONE library. All three panels share it, so a folder dropped on the left
    /// appears on the right and a bin made in one exists in the other. The panels
    /// differ in WHERE a double-click sends the clip, and in nothing else.
    private let model: LibraryModel

    /// The library's contents, read through the model.
    private var sourceItems: [LibraryItem] {
        get { model.items }
        set { model.setItems(newValue) }
    }

    /// The Sources tab's actual contents — every `ConfiguredSource` the person has
    /// added in Settings, as tiles.
    ///
    /// Deliberately NOT held in `LibraryModel`. That model is "the one library, shown
    /// three times" — real media, searchable and binnable, shared identically across
    /// the two sub-mix panels and the asset browser. A configured source is a
    /// different kind of thing: there is exactly one list of them for the whole app
    /// (not one per bus), it is not a clip, and it should never show up mixed into a
    /// clip search. Set from outside (`ShellController`, watching
    /// `PreferenceStore.onChange`) whenever the configured list changes.
    var configuredSourceItems: [LibraryItem] = [] {
        didSet {
            guard currentTab == .sources || gridsByTab[.sources] != nil else { return }
            rebuildGrid(for: .sources)
        }
    }

    /// How THIS browser is drawing the shared library.
    ///
    /// Per panel, not per library. The two sub-mix browsers are used at the same time
    /// to find two different clips for two different tracks, so one being a list while
    /// the other is a grid is the normal case, not a bug.
    private var viewStyle: LibraryViewStyle = .icon
    private var sortField: LibrarySortField = .name
    private var sortAscending = true

    /// The view-style keys for this panel.
    private var viewStyleToggle: VBSlideToggle?

    /// The list view, built lazily — most sessions never leave the grid.
    private var listView: LibraryListView?
    /// The bin sidebar shown in column view.
    private var binSidebar: NSStackView?
    /// Shifts the grid right to make room for the sidebar.
    private var gridLeadingInset: NSLayoutConstraint?
    /// How wide the sidebar is. Narrow: it holds short names, and the grid is the
    /// thing you are actually looking at.
    private static let binSidebarWidth: CGFloat = 92
    /// Which bin the column view is showing. Nil means everything.
    private var focusedBin: String?
    /// The scrolling document, so a rebuilt grid goes back in the same place.
    private var documentView: LibraryDropView?
    private var emptyLabelsByTab: [AssetTab: NSTextField] = [:]
    private var currentTab: AssetTab = .clips

    /// How many thumbnails fit across, recomputed from the panel's actual width.
    ///
    /// ── WHY THIS IS NOT A CONSTANT ──────────────────────────────────────────────
    ///
    /// It was: 3 for a sub-mix library, 6 for the browser. Those numbers were right for
    /// one window size and wrong for every other one — a wider panel left a band of
    /// empty space down the right and a narrower one clipped the last column. The grid
    /// is a grid of fixed-size thumbnails, so the only question is how many fit, and
    /// the panel knows its own width.
    private var columns: Int

    /// The column count this grid was last built at, so a resize rebuilds ONCE when
    /// the answer actually changes rather than on every layout pass.
    private var builtColumns: Int = 0

    /// Called when an item is double-clicked: the clip, its channel, and any marks.
    var onItemOpened: ((LibraryItem, String, ClosedRange<Double>?) -> Void)?

    /// Where double-clicked clips go, and which of the pair is next.
    let destination = ChannelDestination()

    /// Called when files are dropped onto this library, so the app can add them.
    var onFilesDropped: (([URL]) -> Void)?

    /// The EMU tab's contents, supplied at construction.
    ///
    /// Passed IN rather than set afterwards: every tab is built during init, so a view
    /// assigned later would arrive after the tab that needs it had already been made
    /// empty.
    private let emuView: NSView?

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

    /// What is currently typed in the search field.
    private var searchText = ""

    /// Which channels this library keeps playlists for. Empty in the asset browser.
    private let playlistChannels: [String]

    /// The AUTO key, so every library can be kept showing the same state.
    private var autoPlayKey: VBOptionButton?

    /// Called when AUTO is toggled. The preference is global, so all three libraries
    /// are told about it.
    var onAutoPlayChanged: ((Bool) -> Void)?

    /// Which channels the focus control offers. A bus library offers its own pair;
    /// the asset browser, which belongs to no bus, offers all four.
    private var focusChannels: [String] {
        playlistChannels.isEmpty ? ChannelDestination.allChannels : playlistChannels
    }

    /// The Library / A / B tab strip, when this library has playlists.
    private var playlistTabs: NSSegmentedControl?

    /// Which view is showing: nil means the clip grid, a letter means that channel's
    /// queue.
    private var shownPlaylist: String?

    /// The queue views, one per channel, built once and swapped in.
    private var playlistViews: [String: PlaylistView] = [:]

    /// Called when a clip is queued from the context menu: (item, channel, playNext).
    var onItemQueued: ((LibraryItem, String, Bool) -> Void)?

    /// Called when a queued item is removed from a channel's playlist.
    var onQueuedItemRemoved: ((String, PlaylistItem.ID) -> Void)?

    /// - Parameters:
    ///   - items: what the Sources tab shows.
    ///   - columns: the starting guess. The real count comes from the panel's width
    ///     as soon as it has one — see `columns`.
    ///   - showsTabs: true for the asset browser, which is tabbed by asset kind.
    init(
        model: LibraryModel, columns: Int, showsTabs: Bool,
        playlistChannels: [String] = [], emuView: NSView? = nil
    ) {
        self.model = model
        self.playlistChannels = playlistChannels
        self.columns = columns
        self.emuView = emuView
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
        } else if !playlistChannels.isEmpty {
            // The playlist tabs take the slot the disabled "Page 1" popup was
            // occupying — a placeholder for paging that does not exist, sitting in
            // the one row where width is scarce.
            let titles = ["Library"] + playlistChannels
            let tabs = Controls.segmented(
                titles, selected: 0, target: self, action: #selector(playlistTabChanged(_:)))
            tabs.toolTip = "The clip grid, or a source's up-next queue"
            tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
            playlistTabs = tabs
            bottomRow.append(tabs)
        } else {
            bottomRow.append(Controls.popUp(["Page 1"], enabled: false))
        }

        // Where a double-clicked clip goes. Present on every library: the sub-mix
        // libraries default to their own side, and the browser starts on A/B.
        // Only this library's OWN pair. The A/B library feeds A and B; offering it C
        // and D as well made the control four wide in the narrowest row in the
        // window, to reach two channels that have their own library sitting on the
        // other side of the screen. The asset browser keeps all four, because it
        // belongs to no bus.
        let destinationToggle = Controls.segmented(
            focusChannels, selected: 0,
            target: self, action: #selector(destinationChanged(_:)))
        destinationToggle.toolTip = "Focus — where the next clip you open lands"
        destinationToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        destinationControl = destinationToggle
        bottomRow.append(destinationToggle)

        // AUTO — does a clip start playing when it lands in a channel.
        //
        // The behaviour already existed as a preference and had no control anywhere
        // in the window, which meant the only way to discover it was to go looking in
        // Preferences for something you did not know was there.
        // A bin button, top right. Bins can also be made by right-clicking the grid
        // or by dropping a folder, but a visible control is what tells you the
        // feature exists at all.
        let newBinButton = Controls.glyphButton(
            "＋", tooltip: "New bin", target: self, action: #selector(newBinPressed))
        topRow.append(newBinButton)

        let autoPlayKey = VBOptionButton(title: "AUTO")
        autoPlayKey.isOn = true
        autoPlayKey.target = self
        autoPlayKey.action = #selector(autoPlayToggled)
        autoPlayKey.toolTip = "Play a clip as soon as it is loaded into a channel"
        autoPlayKey.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.autoPlayKey = autoPlayKey
        bottomRow.append(autoPlayKey)

        // ── The view-style keys ─────────────────────────────────────────────────
        //
        // Icon, list, column — the three Finder gives you, for the three questions
        // people actually ask of a library. Thumbnails for "which one looks right",
        // a sortable list for "which is the long one", columns for "what is in that
        // bin".
        //
        // The style lives in the MODEL, so all three panels change together. Two
        // libraries showing the same clips in two different layouts would be two
        // things to keep track of, and these panels are already distinguished by the
        // only thing that differs — where their clips go.
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

        // With no tab strip there is no top row to hang the bin button on, so it goes
        // at the end of the bottom one instead of vanishing.
        if topRow.count == 1, let onlyButton = topRow.first {
            topRow.removeAll()
            bottomRow.append(onlyButton)
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
        let items = model.items

        // Every panel rebuilds when the library changes, so the three views of it
        // cannot drift apart.
        model.observe { [weak self] in
            self?.scheduleGridRebuild()
            self?.listView?.reload()
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Build every tab's grid up front and show one. The sets are small and this
        // makes switching instant, which is what a tab strip implies.
        // A non-tabbed panel (the two sub-mix libraries) shows exactly one thing:
        // the searchable, bin-aware clip grid — that is what someone loading A/B/C/D
        // is actually browsing. It used to be pinned to `.sources` as a naming
        // leftover from when "sources" meant "things you can load", before configured
        // hardware sources existed as their own concept.
        let tabs: [AssetTab] = showsTabs ? AssetTab.allCases : [.clips]
        for tab in tabs {
            // EMU is the one tab that is not a grid of thumbnails. A machine has state
            // and controls; a thumbnail has neither, so this tab gets its own view
            // rather than an item that opens something.
            let grid: NSView
            if tab == .emu, let emuView {
                grid = emuView
            } else {
                grid = makeGrid(for: contents(of: tab, sources: items))
            }
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

        // One queue view per channel, built alongside the grids and hidden until its
        // tab is picked. Same reasoning as the grids: the sets are small, and a tab
        // strip implies switching is instant.
        for channel in playlistChannels {
            let queue = PlaylistView(channel: channel)
            queue.translatesAutoresizingMaskIntoConstraints = false
            queue.isHidden = true
            queue.onRemove = { [weak self] id in
                self?.onQueuedItemRemoved?(channel, id)
            }
            document.addSubview(queue)
            playlistViews[channel] = queue
            NSLayoutConstraint.activate([
                queue.topAnchor.constraint(equalTo: document.topAnchor),
                queue.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                queue.trailingAnchor.constraint(equalTo: document.trailingAnchor)
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

        // The focus caret is applied HERE, at construction, not only when something
        // outside calls setDestinationPair. A control whose label is wrong until a
        // controller happens to wire it is a control that is wrong in every context
        // that does not — including, as it turned out, the layout render.
        updateDestinationTitles()
    }

    private var documentHeight: NSLayoutConstraint?

    /// What each tab contains.
    ///
    /// `sources:` is the clip list — named for the parameter's original meaning,
    /// back when this tab set had no separate concept of a configured hardware
    /// source. `.clips` reads it directly; `.sources` does NOT — see
    /// `configuredSourceItems`.
    private func contents(of tab: AssetTab, sources: [LibraryItem]) -> [LibraryItem] {
        switch tab {
        case .sources:
            // Exactly what is configured in Settings > Sources — never a clip. See
            // `configuredSourceItems`'s header for why this cannot come from `model`.
            return configuredSourceItems
        case .clips:
            return sources
        case .generators:
            // Every generator is real and assignable, so they are all available.
            return GeneratorKind.allCases.map {
                LibraryItem(name: $0.displayName, badge: "GEN", isAvailable: true)
            }
        case .graphics, .images:
            // Empty on purpose; the tab says why rather than showing a blank box.
            return []
        case .emu:
            // Not a grid of items at all — EmuBrowserView replaces the grid for this
            // tab, because a machine with its own controls beneath it is not a
            // thumbnail.
            return []
        }
    }

    /// Builds one uniform grid of items.
    private func makeGrid(for items: [LibraryItem]) -> NSView {
        let itemsStack = NSStackView()
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = Theme.Metrics.thumbnailGap

        // Grouped into bins, ungrouped items first. A bin is a heading and the items
        // under it — not a separate view you navigate into — so everything stays
        // visible and searchable at once, which is what a grid is for.
        let ungrouped = items.filter { $0.bin == nil }
        let binNames = Array(Set(items.compactMap(\.bin)).union(
            searchText.isEmpty ? Set(model.binNames) : [])).sorted()

        if !ungrouped.isEmpty || binNames.isEmpty {
            addRows(of: ungrouped, to: itemsStack)
        }
        for name in binNames {
            let heading = BinHeadingField(name: name)
            heading.onRenamed = { [weak self] from, to in
                self?.renameBin(from: from, to: to)
            }
            binHeadings[name] = heading
            itemsStack.addArrangedSubview(heading)
            addRows(of: items.filter { $0.bin == name }, to: itemsStack)
        }
        return itemsStack
    }

    /// Lays a set of items out in rows of `columns`.
    private func addRows(of items: [LibraryItem], to itemsStack: NSStackView) {
        var row: [NSView] = []
        for item in items {
            let view = LibraryItemView(item: item)
            view.queueChannels = playlistChannels
            view.binOwner = self
            view.onQueue = { [weak self] item, channel, playNext in
                self?.onItemQueued?(item, channel, playNext)
            }
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
    }

    // MARK: - Playlists

    @objc private func playlistTabChanged(_ sender: NSSegmentedControl) {
        // Segment 0 is the clip grid; the rest are channels, in order.
        let index = sender.selectedSegment
        shownPlaylist = index <= 0 ? nil : playlistChannels[min(index - 1, playlistChannels.count - 1)]
        applyPlaylistVisibility()
    }

    /// Shows either the clip grid or one channel's queue — never both, and never
    /// neither.
    private func applyPlaylistVisibility() {
        let showingQueue = shownPlaylist != nil
        gridsByTab[currentTab]?.isHidden = showingQueue
        if showingQueue { emptyLabelsByTab[currentTab]?.isHidden = true }
        for (channel, view) in playlistViews {
            view.isHidden = channel != shownPlaylist
        }
        if !showingQueue {
            emptyLabelsByTab[currentTab]?.isHidden = !sourceItems.isEmpty
        }
    }

    /// Hands a channel's queue its current contents.
    func setPlaylist(_ playlist: Playlist, forChannel channel: String) {
        playlistViews[channel]?.setItems(playlist.items)
        // The tab says how many are waiting, so the count is legible without
        // switching to it mid-set.
        guard let tabs = playlistTabs,
              let index = playlistChannels.firstIndex(of: channel) else { return }
        tabs.setLabel(
            playlist.isEmpty ? channel : "\(channel) \(playlist.count)", forSegment: index + 1)
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
    /// Rebuilds the grid on the NEXT runloop turn, coalescing repeated calls.
    ///
    /// The render loop runs on the main thread, so a rebuild is time the picture is
    /// not being drawn. Dropping two dozen files used to rebuild the whole grid
    /// synchronously inside the drop handler — 70 ms, better than two frames, and a
    /// visible stutter at exactly the moment someone is watching the screen.
    ///
    /// Coalescing matters as much as deferring: a drop of a folder can call this once
    /// per file, and doing the work once at the end is the difference between one
    /// hitch and fifty.
    private func scheduleGridRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // On the RUN LOOP, not the main dispatch queue: identical in the live app, but a
        // dispatch block is not drained by a nested `RunLoop.run` — so in the self-QA
        // harness the search never rebuilt, and `rebuildScheduled` stuck at true,
        // silently swallowing every later rebuild in that panel.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuildClipsGrid()
        }
    }

    private var rebuildScheduled = false

    /// Shows whichever view the shared style calls for.
    ///
    /// The grid stays built either way — switching styles is something people do
    /// several times a minute while looking for something, and rebuilding a grid of
    /// thumbnails each time would make the toggle feel expensive.
    private func applyViewStyle() {
        let style = viewStyle

        // COLUMN: a sidebar of bins beside the grid, and the grid shows the chosen one.
        //
        // Finder's column view is miller columns — a chain of them, for a tree. Bins
        // here are ONE level deep and always will be (an item carries a bin name, not a
        // path), so a chain of columns would be a chain of length two with the second
        // always empty. Two panes is the same idea at the depth this library actually
        // has.
        let wantsColumns = style == .column
        binSidebar?.isHidden = !wantsColumns
        if wantsColumns, binSidebar == nil { buildBinSidebar() }
        binSidebar?.isHidden = !wantsColumns
        if wantsColumns { refreshBinSidebar() }
        gridLeadingInset?.constant = wantsColumns ? Self.binSidebarWidth + 6 : 0

        let wantsList = style == .list
        if wantsList, listView == nil, let document = documentView {
            let list = LibraryListView(model: model)
            list.onSortChanged = { [weak self] field, ascending in
                self?.sortField = field
                self?.sortAscending = ascending
            }
            list.onOpen = { [weak self] item in
                guard let self else { return }
                let channel = self.destination.takeNextChannel()
                self.onItemOpened?(item, channel, nil)
                self.updateDestinationTitles()
            }
            document.addSubview(list)
            listView = list
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: document.topAnchor),
                list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                // Tall enough to be worth scrolling, and the document grows with it.
                list.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
            ])
        }
        listView?.isHidden = !wantsList
        listView?.searchText = searchText
        if wantsList { listView?.reload() }

        // The grids hide wholesale while the list is up — including the empty label,
        // which would otherwise sit behind the table saying the library is empty.
        for (tab, grid) in gridsByTab {
            grid.isHidden = wantsList || tab != currentTab
        }
        for (tab, label) in emptyLabelsByTab where wantsList || tab != currentTab {
            label.isHidden = true
        }

        if wantsList, let list = listView, let document = documentView {
            documentHeight?.isActive = false
            documentHeight = document.heightAnchor.constraint(
                greaterThanOrEqualTo: list.heightAnchor)
            documentHeight?.isActive = true
        }
        needsLayout = true
    }

    /// Builds the bin sidebar once.
    private func buildBinSidebar() {
        guard let document = documentView else { return }
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 1
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sidebar)
        binSidebar = sidebar
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: document.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.binSidebarWidth)
        ])
    }

    /// Fills the sidebar with the bins, plus an "All" row.
    private func refreshBinSidebar() {
        guard let sidebar = binSidebar else { return }
        for view in sidebar.arrangedSubviews {
            sidebar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // "All" first and always, because a library with no bins would otherwise show
        // an empty sidebar and an empty grid, which looks broken rather than empty.
        let rows: [String?] = [nil] + model.binNames.map { Optional($0) }
        for bin in rows {
            let key = VBOptionButton(title: bin ?? "ALL")
            key.isOn = bin == focusedBin
            key.toolTip = bin.map { "Show only \($0)" } ?? "Show every clip"
            key.target = self
            key.action = #selector(binRowPressed(_:))
            key.identifier = NSUserInterfaceItemIdentifier(bin ?? "")
            sidebar.addArrangedSubview(key)
            key.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
    }

    @objc private func binRowPressed(_ sender: VBOptionButton) {
        let name = sender.identifier?.rawValue ?? ""
        focusedBin = name.isEmpty ? nil : name
        refreshBinSidebar()
        rebuildGrid(for: currentTab)
    }

    private func rebuildClipsGrid() {
        applyViewStyle()
        guard viewStyle != .list else { return }
        rebuildGrid(for: .clips)
        // The tab on screen too, when it is a different one — a resize changes the
        // column count for EVERY grid, and rebuilding only Clips left whichever tab
        // you were looking at at the old width.
        if currentTab != .clips { rebuildGrid(for: currentTab) }
    }

    /// Rebuilds one tab's grid in place.
    ///
    /// EMU is not a grid — it is a machine with its own controls — so it is skipped
    /// rather than rebuilt into a thumbnail list.
    private func rebuildGrid(for tab: AssetTab) {
        guard tab != .emu, let document = documentView else { return }

        gridsByTab[tab]?.removeFromSuperview()

        // Every tab honours the search field — it is on screen for all of them, and a
        // field that filters one tab and silently ignores the rest looks broken.
        var items = tab == .clips
            ? matching()
            : contents(of: tab, sources: sourceItems).filter {
                LibraryModel.matches($0, search: searchText)
            }
        // In column view the grid shows one bin at a time — that IS the column view.
        if viewStyle == .column, let focusedBin {
            items = items.filter { $0.bin == focusedBin }
        }
        let grid = makeGrid(for: items)
        grid.translatesAutoresizingMaskIntoConstraints = false
        // The VIEW STYLE has a say as well as the tab. `applyViewStyle` hides the grids
        // when the list is up, and this runs AFTER it — so without the style here, a
        // rebuild put the thumbnails straight back on top of the table.
        grid.isHidden = viewStyle == .list || currentTab != tab
        document.addSubview(grid)
        gridsByTab[tab] = grid

        // Held, so switching to column view slides the grid right for the sidebar
        // rather than rebuilding it at a different position.
        let leading = grid.leadingAnchor.constraint(
            equalTo: document.leadingAnchor,
            constant: viewStyle == .column ? Self.binSidebarWidth + 6 : 0)
        if currentTab == tab { gridLeadingInset = leading }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            leading,
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor)
        ])
        emptyLabelsByTab[tab]?.isHidden =
            viewStyle == .list || !items.isEmpty || currentTab != tab
        // An empty grid while searching means "nothing matches", never "your library is
        // empty" — the old text sent people looking for files that were still there.
        emptyLabelsByTab[tab]?.stringValue = searchText.isEmpty
            ? tab.emptyMessage
            : "Nothing in \(tab.displayName) matches “\(searchText)”."

        if currentTab == tab, viewStyle != .list {
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
        scheduleGridRebuild()
        Log.info(.app, "added \(additions.count) item(s) to a library")
    }

    /// Asks for a bin name and makes one. An empty name is a cancel.
    /// Makes an empty bin and puts its name straight into edit mode.
    ///
    /// No dialogue. A bin is a folder — it has no consequences and it can be renamed in
    /// a second — so asking for a name before making one puts a decision in front of an
    /// action that does not need it, and makes three bins cost three dialogues. Every
    /// editing application settled on "make it, select the name, let them type" long
    /// ago, and this is that.
    @objc private func newBinPressed() {
        let name = model.addBin()
        rebuildClipsGrid()
        Log.info(.app, "created bin '\(name)'")

        // After the rebuild, because the heading it selects does not exist until then.
        DispatchQueue.main.async { [weak self] in
            self?.binHeadings[name]?.beginRename()
        }
    }

    /// Renames a bin, and every clip that was in it.
    ///
    /// The items carry the bin NAME rather than an identifier, so a rename has to move
    /// them too — otherwise the old bin keeps its contents and the renamed one is
    /// empty, which looks exactly like the rename having failed.
    private func renameBin(from oldName: String, to newName: String) {
        // Merging into an existing bin is allowed: dropping a folder in already merges
        // by name, so renaming one to match another should do the same rather than
        // refuse.
        model.renameBin(from: oldName, to: newName)
        Log.info(.app, "renamed bin '\(oldName)' to '\(newName)'")
    }

    /// The heading views, so a freshly made bin can be put into edit mode.
    private var binHeadings: [String: BinHeadingField] = [:]

    /// Bins with nothing in them yet. Items carry their own bin name, so a bin with
    /// contents needs no record of its own — but one you have just made and not
    /// filled would otherwise vanish the moment it was created.


    /// Moves an item into a bin, or out of one when `bin` is nil.
    func moveItem(named name: String, toBin bin: String?) {
        model.moveItem(named: name, toBin: bin)
        Log.info(.app, "moved \(name) to \(bin ?? "no bin")")
    }

    /// Every bin this library knows about, filled or not.
    var binNames: [String] {
        model.binNames
    }

    @objc private func autoPlayToggled() {
        onAutoPlayChanged?(autoPlayKey?.isOn ?? true)
    }

    /// Points the key at a state without firing its action, for restoring the saved
    /// preference and for keeping the three libraries agreeing with each other.
    func setAutoPlay(_ isOn: Bool) {
        autoPlayKey?.isOn = isOn
    }

    @objc private func destinationChanged(_ sender: NSSegmentedControl) {
        let channels = focusChannels
        guard channels.indices.contains(sender.selectedSegment) else { return }
        destination.focus(channel: channels[sender.selectedSegment])
        updateDestinationTitles()
    }

    /// Marks which channel the next double-click will fill.
    ///
    /// FOCUS, and it says so. This read "A/B·B", which names two things with a dot
    /// between them and leaves you to guess the relationship — it looked like a
    /// label for the pair rather than a control deciding where your next action
    /// lands. The focused channel now carries a caret, `▸B`, and the unfocused pair
    /// just names itself. The same caret marks the focused channel on an FX card's
    /// selector, because it is the same idea in both places: this is the one that
    /// receives what you do next.
    ///
    /// The channel and not merely the pair, because the focus auto-advances — a
    /// control that silently alternated would surprise you every second clip.
    private func updateDestinationTitles() {
        guard let control = destinationControl else { return }
        let focused = destination.nextChannel
        for (index, channel) in focusChannels.enumerated() {
            control.setLabel(
                channel == focused ? Theme.focusCaret + channel : channel, forSegment: index)
            if channel == focused { control.selectedSegment = index }
        }
        // Colour AS WELL AS the caret. The bus tint is already how this window says
        // A/B from C/D everywhere else, so the focus picks it up rather than
        // inventing a second code — and colour survives being glanced at, which a
        // small caret on its own does not.
        control.selectedSegmentBezelColor = Theme.Color.focusOn
        control.toolTip = "Focus — the next clip you open lands on \(focused), "
            + "then the focus moves to the other channel of that pair"
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
        grid?.isHidden = viewStyle == .list
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

    @objc private func viewStyleChanged(_ sender: VBSlideToggle) {
        let styles = LibraryViewStyle.allCases
        guard styles.indices.contains(sender.selectedIndex) else { return }
        viewStyle = styles[sender.selectedIndex]
        applyViewStyle()
        rebuildGrid(for: currentTab)
        Log.info(.app, "library view is now \(viewStyle.rawValue)")
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        // Was a log line saying filtering "is not built yet", which is a reasonable
        // thing to do once and a poor thing to leave in a search field that looks
        // exactly like one that works.
        searchText = sender.stringValue.trimmingCharacters(in: .whitespaces)
        // Once per keystroke would rebuild the whole grid on every letter typed.
        scheduleGridRebuild()
    }

    /// Items matching the current search, across every bin. Matching on the file NAME
    /// and on the badge, so "dv" finds both the format and anything called dv.
    /// The library's items for THIS browser: its search, its sort.
    ///
    /// Takes no argument any more. It used to be handed a local copy of the items,
    /// which was the shape of the problem — a panel holding its own list is a panel
    /// that can disagree with the others about what is in the library.
    private func matching() -> [LibraryItem] {
        model.items(matching: searchText, sortedBy: sortField, ascending: sortAscending)
    }


    /// The number of thumbnails that fit across the panel right now.
    private var fittingColumns: Int {
        let padding = Theme.Metrics.panelBodyPadding * 2
        let gap = Theme.Metrics.thumbnailGap
        let side = Theme.Metrics.thumbnailSide
        let available = bounds.width - padding
        guard available > side else { return 1 }
        // One thumbnail, then as many "gap plus thumbnail" as will follow it.
        return max(1, Int((available + gap) / (side + gap)))
    }

    override func layout() {
        super.layout()
        let fitting = fittingColumns
        guard fitting != builtColumns, bounds.width > 1 else { return }
        columns = fitting
        builtColumns = fitting
        // Deferred, because rebuilding views from inside a layout pass is how you get
        // a layout loop — and because a live window resize would otherwise rebuild the
        // grid on every intermediate width.
        scheduleGridRebuild()
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
