//
//  LibraryItemView.swift — one cell of the icon view: a clip, or a bin as a folder.
//
//  Purpose : A fixed-size thumbnail with a badge and a caption, which scrubs under the
//            pointer (FCP's hover skim) and takes I and O marks. Bins are drawn as
//            folders with a count, and are renamed in place.
//  Inputs   : an entry to show; clicks, drags and right-clicks.
//  Outputs  : everything a gesture MEANS is decided by the owning LibraryGridView —
//            a cell only reports what happened to it.
//  Connects : LibraryGridView (owner), LibraryModel (marks), ClipThumbnails.
//  Extend   : a new kind of cell is a LibraryCellView subclass. Keep gesture meaning
//            in the grid, so every cell kind selects and drags the same way.
//
//  ── WHY A CELL HANDLES ITS OWN PRESS ────────────────────────────────────────────
//
//  NSCollectionView will track a press on an item itself — select, then drag through
//  its own delegate. That loop waits on the real mouse, so the unattended self-QA
//  (which has no mouse) hung inside it for hours. The cell takes the press instead:
//  it applies the Finder's selection rules through the grid and starts the drag
//  itself, both of which a check can drive. A press on the BACKGROUND still reaches
//  the collection view, which is where rubber-band selection lives.
//

import AppKit
import VideoboyCore

extension NSPasteboard.PasteboardType {
    /// The in and out points a dragged clip carries, as "lower,upper".
    ///
    /// Private to this app: a clip dragged to the Finder is still just a file, and a
    /// file dragged in from the Finder simply has no marks.
    static let videoboyClipRange = NSPasteboard.PasteboardType("com.videoboy.clip-range")
}

/// What a cell reports to the grid that owns it.
protocol LibraryCellOwner: AnyObject {
    func cellPressed(_ cell: LibraryCellView, with event: NSEvent)
    func cellReleased(_ cell: LibraryCellView, with event: NSEvent)
    func cellDoubleClicked(_ cell: LibraryCellView)
    func cellDragged(_ cell: LibraryCellView, with event: NSEvent)
    func cellMenu(_ cell: LibraryCellView, for event: NSEvent) -> NSMenu?
    func cellRenamed(bin oldName: String, to newName: String)
    func cellMarksChanged(_ cell: LibraryItemView, inPoint: Double?, outPoint: Double?)
}

/// What every cell has: an entry, a selected look, and the press-drag-click gesture.
class LibraryCellView: NSView {

    /// What this cell shows. Set by `configure`, because cells are recycled.
    fileprivate(set) var entry: LibraryEntry = .bin("")

    weak var owner: LibraryCellOwner?

    /// Selected: the thumbnail is ringed and the caption sits on an accent pill, as a
    /// selected icon in the Finder is drawn.
    var isSelected = false {
        didSet { if isSelected != oldValue { updateAppearance() } }
    }

    /// Something is being dragged over this cell and would land in it.
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { updateAppearance() } }
    }

    /// Where the current press started, or nil when there is no press in progress.
    private var pressOrigin: NSPoint?
    /// True once this press has become a drag, so the release is not also a click.
    private var pressDragged = false

    /// How far the pointer must move before a press counts as a drag. Three points is
    /// the usual allowance for a hand that is not quite still.
    static let dragThreshold: CGFloat = 3

    func updateAppearance() {}

    /// A press works even while another window (the output, Preferences) is key, so a
    /// clip can be picked up and dragged without a first click spent on activation —
    /// as a Finder icon can be dragged out of a window behind.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pressOrigin = nil
            owner?.cellDoubleClicked(self)
            return
        }
        pressOrigin = event.locationInWindow
        pressDragged = false
        owner?.cellPressed(self, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // AppKit delivers mouseDragged to whichever view took the mouseDown, so this
        // is the idiomatic place to start a drag.
        guard let origin = pressOrigin, !pressDragged else { return }
        let travelled = hypot(
            event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
        guard travelled >= Self.dragThreshold else { return }
        pressDragged = true
        owner?.cellDragged(self, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil }
        guard pressOrigin != nil, !pressDragged else { return }
        owner?.cellReleased(self, with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.cellMenu(self, for: event)
    }

    /// A picture of the cell, so what is dragged looks like what was grabbed.
    func snapshot() -> NSImage? {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

/// A clip, generator or source: a fixed-size thumbnail with a badge and a caption.
///
/// Every item is exactly the same size. Items that size themselves to their caption
/// read as clutter however neatly they are spaced.
final class LibraryItemView: LibraryCellView {

    /// The item shown. For a bin cell see LibraryFolderView.
    var item: LibraryItem {
        entry.item ?? LibraryItem(name: "", badge: "", isAvailable: false)
    }

    private let thumbnail = HoverScrubView()
    private let badge = Controls.monoLabel("", color: Theme.Color.accent, holdsWidth: true)
    private let caption = Controls.label("", font: Theme.Font.tinyLabel, color: Theme.Color.textSecondary)

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        thumbnail.layer?.cornerRadius = 2
        thumbnail.layer?.borderWidth = Theme.Metrics.hairline
        thumbnail.layer?.borderColor = Theme.Color.panelBorder.cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.onMarksChanged = { [weak self] inPoint, outPoint in
            guard let self else { return }
            self.owner?.cellMarksChanged(self, inPoint: inPoint, outPoint: outPoint)
        }

        // holdsWidth: the badge is two or three characters naming what the asset IS,
        // and "…" names nothing.
        badge.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.addSubview(badge)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.lineBreakMode = .byTruncatingMiddle
        caption.alignment = .center
        caption.wantsLayer = true
        caption.layer?.cornerRadius = 3
        // The caption must never widen the cell — a long filename truncates instead.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(thumbnail)
        addSubview(caption)

        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailImageHeight),

            badge.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 2),
            badge.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 3),

            caption.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailCaptionHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Points this recycled cell at an item.
    func configure(item: LibraryItem, marks: (inPoint: Double?, outPoint: Double?)) {
        entry = .item(item)
        thumbnail.item = item
        thumbnail.setInOut(inPoint: marks.inPoint, outPoint: marks.outPoint)
        badge.stringValue = item.badge
        caption.stringValue = item.name
        toolTip = item.url != nil
            ? "\(item.name) — double-click to load · drag to a source · I and O set in and out"
            : item.name
        updateAppearance()
    }

    override func updateAppearance() {
        let available = item.isAvailable
        badge.textColor = available ? Theme.Color.accent : Theme.Color.textTertiary
        thumbnail.layer?.borderWidth = isSelected || isDropTarget ? 2 : Theme.Metrics.hairline
        thumbnail.layer?.borderColor = (isSelected || isDropTarget
            ? Theme.Color.accent : Theme.Color.panelBorder).cgColor
        caption.layer?.backgroundColor = isSelected ? Theme.Color.accent.cgColor : nil
        caption.textColor = isSelected
            ? .white
            : (available ? Theme.Color.textSecondary : Theme.Color.textTertiary)
    }

    /// The marks on the thumbnail, for the double-click and the drag.
    var markedRange: ClosedRange<Double>? { thumbnail.markedRange }

    // MARK: - Pasteboard (shared with the other views and the drop targets)

    /// Set by the self-QA to observe a drag starting, without a real mouse.
    ///
    /// Under the self-QA a real drag session waits for a PHYSICAL mouse-up, and with
    /// nobody at the machine it never comes — unattended `selfqa ui` runs hung for
    /// hours inside AppKit's drag manager. What a check needs to know is that the
    /// drag STARTS and what it carries; both are handed over here instead.
    static var onDragStartedForChecks: (([NSPasteboardItem]) -> Void)?

    /// Every library cell beneath a view, for the self-QA.
    static func all(in view: NSView) -> [LibraryItemView] {
        var found: [LibraryItemView] = []
        if let cell = view as? LibraryItemView { found.append(cell) }
        return found + view.subviews.flatMap { all(in: $0) }
    }

    /// What the library puts on the pasteboard for a clip's FILE.
    ///
    /// One place, so what is written and what the drop targets read cannot drift
    /// apart — which is the only way a drag silently does nothing.
    static func pasteboardItem(for url: URL, range: ClosedRange<Double>? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // Both spellings: `.fileURL` is what a modern reader asks for, and the plain
        // string is what some targets still look for.
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        // The MARKS travel with the clip, so a dragged clip honours them exactly as a
        // double-clicked one does.
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
}

/// A bin, drawn as a folder: open it with a double-click, drop clips on it to file
/// them, rename it in place.
final class LibraryFolderView: LibraryCellView {

    var binName: String { entry.binName ?? "" }

    private let icon = NSImageView()
    private let countLabel = Controls.monoLabel("", color: Theme.Color.textSecondary, holdsWidth: true)
    private let caption = BinNameField()
    private let well = PassThroughView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        well.wantsLayer = true
        well.passesPresses = true
        well.layer?.cornerRadius = 2
        well.layer?.borderWidth = Theme.Metrics.hairline
        well.layer?.borderColor = NSColor.clear.cgColor
        well.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)

        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Bin")?
            .withSymbolConfiguration(configuration)
        icon.contentTintColor = Theme.Color.accent.withAlphaComponent(0.85)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(countLabel)

        caption.onRenamed = { [weak self] old, new in self?.owner?.cellRenamed(bin: old, to: new) }
        addSubview(caption)

        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: topAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailImageHeight),

            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),

            countLabel.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2),
            countLabel.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -3),

            caption.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailCaptionHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    func configure(bin: String, count: Int) {
        entry = .bin(bin)
        caption.setName(bin)
        countLabel.stringValue = "\(count)"
        toolTip = "\(bin) — \(count) item\(count == 1 ? "" : "s") · double-click to open · "
            + "drop clips here to file them"
        updateAppearance()
    }

    /// Puts the name into edit mode, for a bin just made or chosen for renaming.
    func beginRename() { caption.beginRename() }

    override func updateAppearance() {
        well.layer?.backgroundColor = (isSelected || isDropTarget
            ? Theme.Color.accent.withAlphaComponent(0.22) : NSColor.clear).cgColor
        well.layer?.borderColor = (isDropTarget ? Theme.Color.accent : NSColor.clear).cgColor
        well.layer?.borderWidth = isDropTarget ? 2 : Theme.Metrics.hairline
        caption.isHighlightedForSelection = isSelected
    }
}

/// The picture area of a library item, which scrubs under the pointer.
///
/// Split from `LibraryItemView` so the drawing and the mouse tracking are not tangled
/// with the cell's layout. This view owns the playhead and the decoded frame; the
/// marks it draws belong to the library, which it tells whenever I or O is pressed.
final class HoverScrubView: NSView {

    var item: LibraryItem? {
        didSet {
            // A generator's picture can arrive AFTER its tile: ISF generators compile
            // in the background and the tab is rebuilt when each is ready — into the
            // SAME reused cells, with the same id and a new thumbnail. Comparing only
            // id and URL would throw that picture away.
            guard item?.id != oldValue?.id || item?.url != oldValue?.url
                    || item?.thumbnail !== oldValue?.thumbnail else { return }
            // A recycled thumbnail must not show the last clip's picture for a moment.
            scrubPosition = nil
            frameImage = item?.url == nil ? item?.thumbnail : nil
            if window != nil, item?.url != nil { loadFrame(at: 0) }
            needsDisplay = true
        }
    }

    /// Told when I, O or X change the marks, so the library keeps them.
    var onMarksChanged: ((Double?, Double?) -> Void)?

    /// The thumbnail under the pointer right now, so the grid can hand it I and O
    /// while the grid itself has the keyboard.
    private(set) static weak var hovered: HoverScrubView?

    /// 0...1 under the pointer, or nil when not hovering.
    private var scrubPosition: Double?
    /// In and out points, 0...1, as set with I and O.
    private var inPoint: Double?
    private var outPoint: Double?

    private var frameImage: NSImage?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    /// The press belongs to the cell underneath, which accepts it first time.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        Self.hovered = self
        // The keyboard follows the pointer so I and O work without a click first —
        // but never out of a text field. Taking it from the search field meant a
        // pointer drifting over a thumbnail swallowed the rest of what was being typed.
        if let window, !(window.firstResponder is NSText) {
            window.makeFirstResponder(self)
        }
        updateScrub(with: event)
    }

    // The press belongs to the cell, which owns selecting, opening and dragging. Sent
    // explicitly rather than left to NSResponder's forwarding: this view covers the
    // whole thumbnail, so it is what a press actually lands on.
    override func mouseDown(with event: NSEvent) {
        guard let cell = superview as? LibraryCellView else { return super.mouseDown(with: event) }
        cell.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        (superview as? LibraryCellView)?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        (superview as? LibraryCellView)?.mouseUp(with: event)
    }

    /// A right-click on the picture is a right-click on the clip. `NSView` does not
    /// ask the superview, so without this the thumbnail — which covers the cell —
    /// answered "no menu" and nothing appeared.
    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateScrub(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if Self.hovered === self { Self.hovered = nil }
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
    /// no way to synthesise a hover offscreen.
    func scrub(to position: Double?) {
        guard let item, item.url != nil else { return }
        scrubPosition = position
        loadFrame(at: position ?? 0)
        needsDisplay = true
    }

    /// Shows marks without reporting them — for configuring a recycled cell.
    func setInOut(inPoint: Double?, outPoint: Double?) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        needsDisplay = true
    }

    /// The hover position, exposed so a check can tell "the keys did nothing" from
    /// "the pointer was never considered to be over the strip".
    var scrubPositionForChecks: Double? { scrubPosition }

    /// The marked range, or nil when the whole clip is wanted.
    ///
    /// One mark counts: marking only an in point means "from here to the end".
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
    ///
    /// Never waits: a frame not yet decoded arrives on a later run-loop turn, and only
    /// if this view still shows the same clip and still wants that position — so a
    /// quick sweep across a tile, or a recycled cell, cannot land a stale picture.
    private func loadFrame(at position: Double) {
        guard let url = item?.url else { return }
        wantedPosition = position
        ClipThumbnails.shared.request(for: url, at: position) { [weak self] buffer in
            guard let self, self.item?.url == url, self.wantedPosition == position,
                  let buffer, let cgImage = buffer.makeCGImage() else { return }
            self.frameImage = NSImage(
                cgImage: cgImage, size: NSSize(width: buffer.width, height: buffer.height))
            self.needsDisplay = true
        }
    }

    /// The position most recently asked for, so an older answer arriving late is ignored.
    private var wantedPosition: Double?

    /// I, O and X while hovering, as FCP does. Returns false for any other key.
    @discardableResult
    func handleMarkKey(_ event: NSEvent) -> Bool {
        guard let position = scrubPosition else { return false }
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
            return false
        }
        onMarksChanged?(inPoint, outPoint)
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Only plain keys are marks; ⌘A and friends go on up the responder chain.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              handleMarkKey(event) else {
            super.keyDown(with: event)
            return
        }
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

/// A container that is never the target of a press: hit-testing falls through it (and
/// everything inside it) to the view underneath, so a folder cell's icon and count do
/// not swallow the click, drag or right-click meant for the folder.
final class PassThroughView: NSView {
    var passesPresses = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesPresses ? nil : super.hitTest(point)
    }
}
