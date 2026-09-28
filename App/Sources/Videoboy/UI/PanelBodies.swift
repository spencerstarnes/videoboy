//
//  PanelBodies.swift — the contents of each panel in the grid.
//
//  Purpose : One body view per panel type from SPEC 14.2. Each is built from real
//            AppKit controls (SPEC 14.3). Controls whose features are not built yet
//            are present and disabled, never omitted (CLAUDE.md).
//  Inputs  : construction parameters (channel letter, bus identity).
//  Outputs : views handed to `PanelView` as its body.
//  Connects: Controls (the control factories), MetalPreviewView (the video boxes),
//            Theme (every measurement).
//  Extend  : when a feature ships, enable its controls here and wire them to Core.
//            Keep the arrangement as the mockup has it.
//

import AppKit
import VideoboyCore

// MARK: - Source panels

/// A source channel: a 4:3 preview plus its shuttle strip (SPEC 14.2, SPEC 12).
final class SourcePanelBody: NSView {

    /// The preview this channel draws into.
    let preview: MetalPreviewView

    /// Channel letter, A-D.
    let channel: String

    private var generatorPopUp: NSPopUpButton?
    /// The shuttle scrub track. Exposed so the shell can give it a mapping address.
    private(set) var scrubFader: VBFader?
    private var stepButton: VBStepButton?
    private var loopKey: VBOptionButton?
    private var loopMode: LoopMode = .loop

    /// One flat transport key, in the same family as the bus keys.
    private func shuttleKey(
        _ glyph: String, _ tooltip: String, _ action: Selector
    ) -> VBOptionButton {
        let key = VBOptionButton(title: glyph)
        key.target = self
        key.action = action
        key.toolTip = tooltip
        return key
    }

    /// Cycles loop → ping-pong → one shot, the way the step key cycles its ladder.
    @objc private func loopKeyPressed(_ sender: VBOptionButton) {
        let all = LoopMode.allCases
        let index = all.firstIndex(of: loopMode) ?? 0
        loopMode = all[(index + 1) % all.count]
        // Always lit: every mode is a real mode, so "off" would be a lie. The glyph
        // says which one, and the tooltip spells it out.
        sender.isOn = true
        sender.setTitle(loopMode.shuttleGlyph)
        sender.toolTip = loopMode.displayName
        onLoopModeChanged?(loopMode)
    }

    /// Shows a loop mode set from outside (a template load) without firing it.
    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        loopKey?.setTitle(mode.shuttleGlyph)
        loopKey?.toolTip = mode.displayName
    }

    /// Loads a file into this channel. Wired by the app; nil until then.
    var onLoadRequested: (() -> Void)?

    /// Called when the button is pressed while media IS loaded.
    var onEjectRequested: (() -> Void)?

    /// The Load/Eject button, retitled as the channel fills and empties.
    private weak var loadButton: NSButton?

    /// The full transport, shown only while the pointer is over this panel.
    private weak var shuttleScrim: NSView?

    /// The playhead strip. Always visible, and the scrubbing surface.
    private(set) weak var miniPlayBar: VBMiniPlayBar?

    /// This source's fill key. It lives in the panel's HEADER, not on the picture —
    /// `PanelSet` puts it there — so nothing in the body refers to its position.
    let fillKey = VBOptionButton(title: PreviewFill.fit.displayName.uppercased())

    /// How this source's picture fills its window.
    /// How this channel frames its picture IN THE FEED (the engine applies it). The
    /// monitor shows the feed as it is — already canvas-shaped — so it always fits;
    /// applying the mode here as well cropped or stretched the picture a second time.
    private var previewFill: PreviewFill = .fit {
        didSet {
            preview.fillMode = .fit
            fillKey.setTitle(previewFill.displayName.uppercased())
        }
    }

    /// The framing this panel's key shows — for self-QA and templates.
    var fillForChecks: PreviewFill { previewFill }

    /// Presses the key as a click does — for self-QA.
    func cycleFillForChecks() { fillCycled() }

    /// Called when this source's fill mode changes.
    var onFillChanged: ((PreviewFill) -> Void)?

    /// Points the key at a mode without firing its action.
    func setFill(_ fill: PreviewFill) {
        previewFill = fill
    }

    @objc private func fillCycled() {
        let all = PreviewFill.allCases
        guard let index = all.firstIndex(of: previewFill) else { return }
        let backwards = NSEvent.modifierFlags.contains(.control)
        previewFill = all[backwards
            ? (index - 1 + all.count) % all.count
            : (index + 1) % all.count]
        onFillChanged?(previewFill)
    }

    /// Swaps the resting line for the full transport, and back.
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            // Only the shuttle comes and goes. The play bar is PERSISTENT: it is the
            // scrubbing surface, and a scrubber that appears only once the pointer is
            // already on it is one you cannot aim at.
            shuttleScrim?.isHidden = !isHovered
        }
    }

    /// Whether this channel currently holds media, which is the only thing that
    /// decides whether the button loads or ejects.
    private var hasMedia = false

    /// Called when the File row is chosen: the channel goes back to its file.
    /// Generators are not in this menu — they are assigned from the Generators tab.
    var onFileSelected: (() -> Void)?

    /// Called when the Camera row is chosen in the source menu.
    var onCameraSelected: (() -> Void)?

    /// Called when the Amiga (EMU) row is chosen in the source menu.
    var onEmulatorSelected: (() -> Void)?

    /// Shows which file this channel is playing, beside the channel letter.
    ///
    /// The channel letter alone is what a preview shows when empty; once something is
    /// loaded the useful question is WHICH clip, because four panels of moving
    /// pictures look alike at thumbnail size.
    func setMediaName(_ name: String?) {
        preview.caption = name.map { "\(channel) · \($0)" } ?? channel
        // One button, two jobs, and the media is what says which. Keeping a separate
        // eject key next to Load would mean a control that is dead half the time in
        // the narrowest panel in the window.
        hasMedia = name != nil
        loadButton?.title = hasMedia ? "Eject" : "Load"
        loadButton?.toolTip = hasMedia
            ? "Take this clip out of channel \(channel)"
            : "Choose a video file for channel \(channel)"
    }

    // MARK: - Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedURL(from: sender) != nil || droppedReference(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        // A generator or a configured source from the asset browser carries a
        // reference and no file. Checked FIRST: the first item decides, as it does
        // for a file, and a reference is never also a file.
        if let reference = droppedReference(from: sender) {
            onReferenceDropped?(reference)
            return true
        }
        guard let clip = droppedClip(from: sender) else { return false }
        onClipDropped?(clip.url, clip.range)
        return true
    }

    /// The library reference ("generator:3", "isf:<id>", "source:<id>") the first
    /// dragged item carries, if it is not a file.
    private func droppedReference(from sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.pasteboardItems?.first?.string(forType: .videoboyLibraryReference)
    }

    /// The first file URL on the pasteboard, if there is one.
    private func droppedURL(from sender: NSDraggingInfo) -> URL? {
        Self.fileURL(from: sender.draggingPasteboard)
    }

    /// The clip a drop is carrying, with whatever in and out points were marked on it.
    private func droppedClip(from sender: NSDraggingInfo) -> (url: URL, range: ClosedRange<Double>?)? {
        guard let url = Self.fileURL(from: sender.draggingPasteboard) else { return nil }
        return (url, LibraryItemView.markedRange(from: sender.draggingPasteboard))
    }

    /// Reads a file URL off a pasteboard, however it was written.
    ///
    /// Static and shared so the self-QA can exercise it against what the library
    /// actually writes. A drag that does nothing is almost always a reader and a
    /// writer disagreeing about the type, and that is not visible from either side.
    static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let first = urls.first {
            return first
        }
        if let string = pasteboard.string(forType: .fileURL), let url = URL(string: string) {
            return url
        }
        if let path = pasteboard.string(forType: .string), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Jump to the start or the end of the clip.
    var onSeekToStart: (() -> Void)?
    var onSeekToEnd: (() -> Void)?
    /// Step one frame back or forward.
    var onStepBack: (() -> Void)?
    var onStepForward: (() -> Void)?
    /// Scrub to a 0...1 position.
    var onScrub: ((Double) -> Void)?
    /// Loop behaviour changed.
    var onLoopModeChanged: ((LoopMode) -> Void)?

    /// A file was dropped on this source, from the library or from the Finder.
    /// A clip was dropped on this source, with whatever in and out points it was
    /// marked with in the library. The range is nil when nothing was marked, or when
    /// the file came from the Finder rather than from a library cell.
    var onClipDropped: ((URL, ClosedRange<Double>?) -> Void)?

    /// A generator or configured source was dropped on this source, by reference —
    /// see `LibraryItem.reference`.
    var onReferenceDropped: ((String) -> Void)?

    /// Highlighted while a drop is hovering, so the target is obvious before release.
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            preview.layer?.borderWidth = isDropTarget ? 2 : Theme.Metrics.hairline
            preview.layer?.borderColor = isDropTarget
                ? Theme.Color.accent.cgColor : Theme.Color.panelBorder.cgColor
        }
    }
    /// Playback timing changed — live, or stepped on a subdivision.
    var onTimingChanged: ((PlaybackTiming) -> Void)?

    init(channel: String) {
        self.channel = channel
        self.preview = MetalPreviewView(
            caption: channel, recordLabel: channel, showsAutoPlay: true)
        super.init(frame: .zero)

        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        // Accepts clips dragged from a library AND files dragged from the Finder.
        // The same type, so there is one drop path rather than a private one for the
        // library that would work while the obvious gesture did not.
        registerForDraggedTypes([.fileURL, .videoboyLibraryReference])

        // Shuttle strip: transport buttons, a scrub track, and the loop-mode toggle.
        // Every source gets one (SPEC 14.2).
        // Four keys and a scrub track, in the same flat family as the bus keys and
        // the option buttons — they were small bezelled push buttons, which is the
        // one visual language in this window that belongs to a settings dialogue
        // rather than to a piece of video kit.
        //
        // Simplified as well as restyled: the step-back and step-forward pair became
        // one key each side of play, and the loop mode stopped being a three-segment
        // control. Segments cost the width of all three states to show one, in the
        // narrowest column of the window; a key that cycles costs the width of one.
        let toStart = shuttleKey("⇤", "Jump to the start", #selector(seekStartPressed))
        let back = shuttleKey("◀", "Step back one frame", #selector(stepBackPressed))
        let play = shuttleKey("▶", "Play or pause this source", #selector(playPressed))
        let forward = shuttleKey("▶|", "Step forward one frame", #selector(stepForwardPressed))

        let scrub = Controls.fader(
            value: 0, compact: true, target: self, action: #selector(scrubbed(_:)))
        self.scrubFader = scrub

        let loopKey = VBOptionButton(title: LoopMode.loop.shuttleGlyph)
        loopKey.isOn = true
        loopKey.target = self
        loopKey.action = #selector(loopKeyPressed)
        loopKey.toolTip = "Loop, ping-pong or one shot"
        self.loopKey = loopKey

        let shuttle = Controls.row([toStart, back, play, forward, scrub, loopKey], spacing: 3)
        shuttle.translatesAutoresizingMaskIntoConstraints = false
        scrub.setContentHuggingPriority(.init(1), for: .horizontal)

        // The shuttle sits ON the picture rather than under it.
        //
        // In a source panel nothing sets the preview's height — it is whatever is
        // left once the controls have taken theirs — so every row of chrome comes
        // straight out of the picture, and these panels are the shortest in the
        // window. Floating the transport over the bottom of the image is what every
        // video player does for the same reason, and it hands a whole row back to
        // the preview.
        //
        // The scrim is what makes it legible: white keys over an arbitrary frame of
        // video are unreadable about half the time, and a live instrument cannot
        // have a play button you have to hunt for against bright footage.
        let shuttleScrim = NSView()
        shuttleScrim.wantsLayer = true
        shuttleScrim.layer?.backgroundColor = Theme.Color.shuttleScrim.cgColor
        shuttleScrim.layer?.cornerRadius = Theme.Metrics.buttonCornerRadius
        shuttleScrim.translatesAutoresizingMaskIntoConstraints = false
        shuttleScrim.isHidden = true
        addSubview(shuttleScrim)
        self.shuttleScrim = shuttleScrim

        // At rest the panel shows one slim line instead of the whole transport, the
        // way QuickTime and anything else built on AVKit does. The keys are one
        // pointer-move away, and in the meantime the picture is not competing with a
        // row of buttons it does not need.
        let miniBar = VBMiniPlayBar()
        miniBar.translatesAutoresizingMaskIntoConstraints = false
        miniBar.onScrub = { [weak self] position in self?.onScrub?(position) }
        addSubview(miniBar)
        self.miniPlayBar = miniBar

        // Load becomes Eject once there is something to eject, the way a deck's one
        // slot both takes a tape and gives it back. There was no eject at all before
        // this: a clip could be put into a channel and never taken out again.
        let load = Controls.button("Load", target: self, action: #selector(loadOrEjectPressed))
        load.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.loadButton = load

        // The source KIND: file, camera or emulator. Generators are chosen from the
        // asset browser's Generators tab, where each has a thumbnail (SPEC 6A: they
        // are still assignable to any of A/B/C/D, by the destination pair).
        let generatorPopUp = Controls.popUp(
            // Every KIND of source a channel can take, in one list. The camera and the
            // emulator were reachable from neither this menu nor anywhere else on the
            // panel, which made them feel absent rather than unbuilt — "I don't see my
            // webcam" was exactly that.
            SourceKindMenu.titles(),
            target: self, action: #selector(generatorChanged(_:))
        )
        self.generatorPopUp = generatorPopUp

        // Step playback on a DJ deck's rules: one key, not a menu. The rates are a
        // ladder you walk by feel while watching the picture, and opening a popup to
        // do that takes your eyes off the thing you are timing against.
        let stepButton = VBStepButton()
        stepButton.onTimingChanged = { [weak self] timing in
            self?.onTimingChanged?(timing)
        }
        self.stepButton = stepButton

        // Load, source and step on ONE row rather than two.
        //
        // The step key used to have a row to itself, with a "Step" caption beside it
        // and a spacer filling the rest — a whole row of the shortest panel in the
        // window spent on one small button. In the source panels nothing sets the
        // preview's height: it is simply what is left after the controls have taken
        // theirs, so a row of chrome is subtracted directly from the picture. The
        // caption goes too; the key already reads STEP, or 1/4, or whatever rate it
        // is on, which is the caption.
        // FILL, per source. It used to be one global key in the output bar, which
        // meant a 16:9 clip on A and a 4:3 clip on B could not be framed differently —
        // and the one place you are looking when you notice a clip is the wrong shape
        // is the panel showing it.
        //
        // In the panel's HEADER, not on this row. As the last key on the hover row it
        // was the first thing squeezed off the end — FIT is narrow, STRETCH and CENTRE
        // are not, and Eject is wider than Load — and in a short panel the row rose
        // into the record lamp and auto-play glyph in the picture's top corner. The
        // header's right end is empty, always visible, and never over the picture.
        fillKey.isCompact = true
        fillKey.toolTip = "How this source's picture fills its window: Fit, Fill, "
            + "Stretch or Centre. Click to cycle; Control-click to go back."
        fillKey.target = self
        fillKey.action = #selector(fillCycled)

        let sourceRow = Controls.row([load, generatorPopUp, stepButton, Controls.spacer()],
                                     spacing: 4)
        sourceRow.translatesAutoresizingMaskIntoConstraints = false

        // Load, source and step live ON the picture with the shuttle, not under it.
        //
        // Everything in this graph is 720x480 — the signal in and out is SD NTSC and
        // every texture is that size — so a source panel's cell is very nearly 4:3
        // already. Any row of chrome below the picture is therefore height the
        // picture could have had, and these panels are the shortest in the window.
        // The shuttle moved onto the image for this reason; this row follows it.
        let overlayStack = NSStackView(views: [sourceRow, shuttle])
        overlayStack.orientation = .vertical
        overlayStack.alignment = .leading
        overlayStack.spacing = 4
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        shuttleScrim.addSubview(overlayStack)

        let padding = Theme.Metrics.panelBodyPadding
        let scrimInset: CGFloat = 4
        NSLayoutConstraint.activate([
            // The picture takes the WHOLE cell. Every control that used to sit under
            // it is now on it, appearing on hover.
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            overlayStack.leadingAnchor.constraint(equalTo: shuttleScrim.leadingAnchor, constant: 4),
            overlayStack.trailingAnchor.constraint(equalTo: shuttleScrim.trailingAnchor, constant: -4),
            overlayStack.topAnchor.constraint(equalTo: shuttleScrim.topAnchor, constant: 4),
            overlayStack.bottomAnchor.constraint(equalTo: shuttleScrim.bottomAnchor, constant: -4),

            miniBar.leadingAnchor.constraint(
                equalTo: preview.leadingAnchor, constant: scrimInset + 4),
            miniBar.trailingAnchor.constraint(
                equalTo: preview.trailingAnchor, constant: -(scrimInset + 4)),
            miniBar.bottomAnchor.constraint(
                equalTo: preview.bottomAnchor, constant: -Theme.MiniPlayBar.bottomClearance),
            miniBar.heightAnchor.constraint(equalToConstant: Theme.MiniPlayBar.height),

            shuttleScrim.leadingAnchor.constraint(
                equalTo: preview.leadingAnchor, constant: scrimInset),
            shuttleScrim.trailingAnchor.constraint(
                equalTo: preview.trailingAnchor, constant: -scrimInset),
            // Sits ABOVE the play bar, clear of it, so the keys never cover the
            // thing they are controlling.
            shuttleScrim.bottomAnchor.constraint(
                equalTo: miniBar.topAnchor, constant: -Theme.MiniPlayBar.shuttleGap),

            sourceRow.leadingAnchor.constraint(equalTo: overlayStack.leadingAnchor),
            shuttle.leadingAnchor.constraint(equalTo: overlayStack.leadingAnchor),
            shuttle.trailingAnchor.constraint(equalTo: overlayStack.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func loadOrEjectPressed() {
        if hasMedia {
            Log.info(.app, "eject requested for source \(channel)")
            onEjectRequested?()
        } else {
            Log.info(.app, "load requested for source \(channel)")
            onLoadRequested?()
        }
    }

    /// Play/pause for this channel. Wired by the app.
    var onPlayToggled: (() -> Void)?

    @objc private func playPressed() {
        Log.info(.app, "play toggled on source \(channel)")
        onPlayToggled?()
    }

    @objc private func seekStartPressed() { onSeekToStart?() }
    @objc private func seekEndPressed() { onSeekToEnd?() }
    @objc private func stepBackPressed() { onStepBack?() }
    @objc private func stepForwardPressed() { onStepForward?() }

    @objc private func scrubbed(_ sender: VBFader) {
        onScrub?(sender.value)
    }

    /// Double-clicking the picture plays or pauses, the way it does in every video
    /// player. The transport keys are on a hover overlay now, so the picture itself
    /// being dead to a click made the most obvious gesture in the window do nothing.
    ///
    /// Only a DOUBLE click: a single click on a source panel is how you focus it, and
    /// making that also toggle playback would make a stray click stop the show.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else {
            super.mouseDown(with: event)
            return
        }
        Log.info(.app, "double-click play/pause on source \(channel)")
        onPlayToggled?()
    }

    // MARK: - Hover

    // The transport appears on hover, so the panel needs a tracking area and has to
    // rebuild it whenever it resizes — an area is in fixed coordinates and does not
    // follow the view's bounds on its own.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    /// Moves the scrub track to follow playback, without firing its action.
    /// The trimmed range this source is playing, drawn on the play bar.
    func setMarkedRange(_ range: ClosedRange<Double>?) {
        miniPlayBar?.markedRange = range
    }

    /// Shows the timing the node is actually on.
    ///
    /// Needed because loading is not the only thing that decides timing any more: a
    /// folder of photographs comes up stepped to the beat rather than continuous. The
    /// key has to say so, or it reads STEP-off while the clip is stepping — the same
    /// switch-disagrees-with-engine problem the bus effects had at launch.
    func setTiming(_ timing: PlaybackTiming) {
        stepButton?.setTiming(timing)
    }

    func setScrubPosition(_ position: Double) {
        scrubFader?.value = position
        // The resting line reads the same playhead as the shuttle's track, so the
        // two never disagree about where the clip is when hovering swaps them.
        miniPlayBar?.progress = position
    }

    @objc private func generatorChanged(_ sender: NSPopUpButton) {
        switch SourceKindMenu.kind(at: sender.indexOfSelectedItem) {
        case .file:
            onFileSelected?()
        case .camera:
            onCameraSelected?()
        case .emulator:
            onEmulatorSelected?()
        }
    }
}

/// What a channel's source menu offers, and what each row means.
///
/// One place, because the menu and the handler reading it by index is exactly the
/// pairing that drifts — add a row to one and the other quietly selects the wrong
/// thing, with no compiler error and no obvious symptom.
enum SourceKindMenu {

    enum Kind {
        case file
        case camera
        case emulator
    }

    /// File, the camera and the emulator. Generators live in the asset browser's
    /// Generators tab, where each one has a picture, not in this menu.
    static func titles() -> [String] {
        ["File", "Camera", "Amiga (EMU)"]
    }

    static func kind(at index: Int) -> Kind {
        switch index {
        case 0: .file
        case 1: .camera
        default: .emulator
        }
    }
}

// MARK: - Preview-only panels

/// Sub Mix ONE / TWO / Program: a large 4:3 preview, optionally with the blend
/// controls for the composite it represents (SPEC 14.2).
final class PreviewPanelBody: NSView {

    let preview: MetalPreviewView

    /// Called when the blend mode changes, with the chosen mode.
    var onBlendModeChanged: ((BlendMode) -> Void)?


    /// Called when one of the scope keys is pressed, with what it means.
    ///
    /// One callback carrying an enum rather than seven callbacks: the panel does not
    /// decide what any of these DO, it reports which was pressed, and the shell — which
    /// owns the selection — works out the rest.
    var onScopeKeyPressed: ((ScopeKey) -> Void)?

    /// What a scope key stands for.
    enum ScopeKey: Hashable {
        /// One of the four instruments.
        case kind(ScopeKind)
        /// Over the picture, rather than over black.
        case overlay
        /// In the lower-third band.
        case lowerThird
        /// NAME: each channel's clip name, as a line of text.
        case fileName
        /// TC: each channel's playhead, as drop-frame timecode.
        case timecode
        /// DATA BURN: into the sub-mix picture itself. Sub-mixes only.
        case burn
    }

    /// The scope keys, so their lit state can be set from the selection.
    private var scopeKeys: [ScopeKey: VBOptionButton] = [:]

    /// - Parameter showsBlendControls: true for the composites that carry a blend
    ///   mode — the two sub-mixes and the program.
    /// - Parameter offersDataBurn: true for the two sub-mixes. PROGRAM has no burn
    ///   key: anything burned into a sub-mix reaches it through the mix.
    init(caption: String, showsBlendControls: Bool = false, recordLabel: String? = nil,
         offersDataBurn: Bool = false) {
        // No send glyph on the picture: these are the big previews, the ones actually
        // being watched, and the bar below has room for it. See the row built further
        // down.
        self.preview = MetalPreviewView(
            caption: caption, recordLabel: recordLabel, showsRoutingOverlay: false)
        super.init(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        var bottomAnchorTarget = bottomAnchor
        var bottomConstant: CGFloat = -2

        if showsBlendControls {
            // BLEND moved to the fader panel beneath this one. It decides how the two
            // layers combine, and the crossfader decides how much of each — they are
            // two halves of one question, and they were two panels apart.

            // The send glyph, off the picture and onto the bar.
            let routing = Controls.glyphButton(
                "􀝪", tooltip: "Send this to a display",
                target: self, action: #selector(routingPressed(_:)))
            if let image = NSImage(
                systemSymbolName: "airplayvideo", accessibilityDescription: "Send to a display") {
                image.isTemplate = true
                routing.image = image
                routing.title = ""
            }
            routing.contentTintColor = Theme.Color.textTertiary

            // ── The scope keys ──────────────────────────────────────────────────
            //
            // Was ONE button that cycled five presets. Four instruments and three
            // placement choices is sixteen useful combinations, and a cycle can only
            // offer the handful someone thought of in advance — reaching a vectorscope
            // meant clicking until it came round, and a vectorscope in the corner was
            // not reachable at all.
            //
            // Seven keys instead: what to draw, where to put it, and whether it goes to
            // air. Each is one click. They are VBOptionButtons rather than push buttons
            // because they are STATES, and a lit key is how this app says "on"
            // everywhere else.
            var scopeRow: [NSView] = []
            let instruments: [(ScopeKind, String)] = [
                (.waveform, "WFM"), (.parade, "RGB"),
                (.histogram, "HIST"), (.vectorscope, "VEC")
            ]
            for (kind, label) in instruments {
                let key = makeScopeKey(.kind(kind), title: label,
                                       tooltip: "\(kind.displayName) — click again to turn it off")
                scopeRow.append(key)
            }

            // The data lines sit with the instruments: they are more things to SHOW,
            // and OVER / L3 / DATA BURN act on them exactly as on a scope.
            scopeRow.append(makeScopeKey(
                .fileName, title: "FILE",
                tooltip: "Show the file name each channel is playing. A channel its "
                    + "fader shuts out keeps its label with nothing after it."))
            scopeRow.append(makeScopeKey(
                .timecode, title: "TC",
                tooltip: "Show where each channel's playhead is, as drop-frame "
                    + "timecode (HH:MM:SS;FF)."))

            // A gap: the keys on the left say WHAT, the ones on the right say WHERE
            // and WHETHER. Without it, a row of identical keys reads as one undifferentiated
            // run and DATA BURN is the last thing you want lost in a row.
            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.widthAnchor.constraint(equalToConstant: 6).isActive = true
            scopeRow.append(gap)

            scopeRow.append(makeScopeKey(
                .overlay, title: "OVER",
                tooltip: "Draw the scopes over the picture. Off puts them over black, "
                    + "for reading levels without the picture distracting."))
            scopeRow.append(makeScopeKey(
                .lowerThird, title: "L3",
                tooltip: "Put the scopes in the lower-third band instead of filling "
                    + "the frame."))

            // Tally red, because this one changes what an audience sees. Every other
            // key on this row is a monitoring choice that cannot reach the output.
            if offersDataBurn {
                scopeRow.append(makeScopeKey(
                    .burn, title: "DATA\nBURN", colour: Theme.Color.tallyOnAir,
                    tooltip: "Burn the scopes, names and timecode INTO this sub-mix's "
                        + "picture, so they go to air whenever this sub-mix is in the "
                        + "programme mix. Font and style: Settings → Data Burn."))
            }

            // The send glyph, then everything else pushed right. One spacer, so the
            // scope keys sit as one block against the trailing edge instead of being
            // spread by a popup that is no longer there.
            // Compact keys and 2pt spacing: FILE, TC and DATA BURN made this row ~70pt
            // wider, and at the standard padding it no longer fit a sub-mix panel.
            for case let key as VBOptionButton in scopeRow { key.isCompact = true }
            let row = Controls.row([routing, Controls.spacer()] + scopeRow, spacing: 2)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
            ])
            bottomAnchorTarget = row.topAnchor
            bottomConstant = -3
        }

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            preview.bottomAnchor.constraint(equalTo: bottomAnchorTarget, constant: bottomConstant)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Builds one scope key and remembers it, so its lit state can be set later.
    private func makeScopeKey(
        _ key: ScopeKey, title: String,
        colour: NSColor = Theme.Color.accent, tooltip: String
    ) -> VBOptionButton {
        let button = VBOptionButton(title: title, onColour: colour)
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(scopeKeyPressed(_:))
        // Holds its full width: a squeezed row must never clip a key's label.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeKeys[key] = button
        return button
    }

    /// The bar's send glyph. Forwards to the preview's own routing callback, so the
    /// shell wires ONE thing whether the glyph is on the picture or on the bar.
    @objc private func routingPressed(_ sender: NSButton) {
        preview.onRoutingRequested?(sender)
    }

    @objc private func scopeKeyPressed(_ sender: VBOptionButton) {
        guard let key = scopeKeys.first(where: { $0.value === sender })?.key else { return }
        onScopeKeyPressed?(key)
    }

    /// Updates the tab's title to name the mode it is now in.
    /// Lights the keys to match the selection.
    ///
    /// Driven from the selection rather than from the keys' own clicks, so the panel
    /// has no opinion about state — the shell owns it, and the keys always show what is
    /// actually happening rather than what was last pressed.
    func setScopeSelection(_ selection: ScopeSelection) {
        for kind in ScopeKind.allCases {
            scopeKeys[.kind(kind)]?.isOn = selection.kinds.contains(kind)
        }
        scopeKeys[.overlay]?.isOn = selection.isOverlaid
        scopeKeys[.lowerThird]?.isOn = selection.isLowerThird
        scopeKeys[.fileName]?.isOn = selection.showsFileName
        scopeKeys[.timecode]?.isOn = selection.showsTimecode
        scopeKeys[.burn]?.isOn = selection.isBurnedIn

        // The placement keys mean nothing with no instrument chosen, and DATA BURN
        // means nothing with nothing at all to burn. Disabled rather than hidden, per
        // the house rule — a key that vanishes and comes back is harder to learn than
        // one that greys.
        scopeKeys[.overlay]?.isEnabled = selection.isShowing
        scopeKeys[.lowerThird]?.isEnabled = selection.isShowing
        scopeKeys[.burn]?.isEnabled = selection.hasAnything
    }

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        // By title, not by index: the menu has separator rows between the groups, so
        // an index here is the item's position INCLUDING the rules above it.
        guard let title = sender.titleOfSelectedItem,
              let mode = BlendMode.allCases.first(where: { $0.displayName == title }) else { return }
        Log.info(.graph, "blend mode set to \(mode.displayName)")
        onBlendModeChanged?(mode)
    }

}

// MARK: - Faders

/// A crossfader panel: Cut, Fade, cut-on-beat, Auto, mapping badges, the fader
/// itself and its numeric value (SPEC 14.2).
final class FaderPanelBody: NSView, FloatingHitTargets {

    /// The crossfader. 0 is the left source, 1 is the right.
    let fader: VBFader
    /// Live numeric readout beside the fader.
    /// The numeric readout that used to sit above the centre of the crossfader.
    ///
    /// Kept as an object but no longer added to the view: the cap's position on the
    /// track already says where the fader is, continuously and without being read,
    /// and a number floating over the middle of a crossfader is both redundant and
    /// exactly where the eye goes during a transition. Still updated, so anything
    /// that wants to show it again — or read it in a test — has it.
    private let valueLabel = Controls.monoLabel("0.50")

    /// Called whenever the fader moves, with the new 0...1 position.
    var onFaderMoved: ((Double) -> Void)?
    /// Called when a bus key is pressed, with the position to cut to: 0 for the
    /// left source, 1 for the right.
    var onCutTo: ((Double) -> Void)?
    /// Called when Fade is pressed, with the chosen rate.
    var onFade: ((FadeRate) -> Void)?
    /// Called when cut-on-beat is switched on or off.
    var onBeatCutToggled: ((Bool) -> Void)?
    private var leftKey: VBBusButton?
    private var rightKey: VBBusButton?
    private var beatCutButton: VBOptionButton?
    private var rateControl: VBSlideToggle?

    /// Called when CUT is pressed: take the other source, now.
    var onCutRequested: (() -> Void)?

    /// Called when this fader gains or loses a sweep, so the controller can start or
    /// stop driving it.
    var onSweepChanged: (() -> Void)?

    /// Called when a button on this panel is armed or disarmed for beat-flipping.
    var onButtonAutomationChanged: (() -> Void)?

    private weak var cutButton: VBOptionButton?
    /// A/B ROLL and ADV — only on the two sub-mix faders.
    private(set) weak var rollButton: VBOptionButton?
    private(set) weak var advanceButton: VBOptionButton?
    /// ROLL / ADV toggled by a click (a MIDI toggle goes through `setRoll`/`setAdvance`).
    var onRollToggled: ((Bool) -> Void)?
    var onAdvanceToggled: ((Bool) -> Void)?
    private weak var fadeButton: VBOptionButton?
    private weak var sweepRateKey: VBStepButton?
    private weak var sweepCancelButton: NSButton?

    /// One tap-rate key per button that can be armed to flip on the beat — CUT and
    /// FADE turn a transition into a strobe; BEAT flips whether the *next* one waits.
    /// Hidden until its button is armed, same as `sweepRateKey` is until the fader
    /// carries marks: an unarmed control showing a rate nobody set is a dial with
    /// nothing to say.
    private weak var cutRateKey: VBStepButton?
    private weak var fadeRateKey: VBStepButton?
    private weak var beatRateKey: VBStepButton?

    /// Everything that would fight an automated fader, so it can be greyed while one
    /// is running.
    private var manualControls: [NSControl] {
        [leftKey, rightKey, cutButton, fadeButton, beatCutButton, rateControl]
            .compactMap { $0 }
    }

    /// Shows or hides the sweep controls and disables the manual ones.
    ///
    /// A fader driving itself and a CUT key that still works are two things fighting
    /// over the same value — whichever ran last wins, which looks like the control is
    /// broken rather than overridden. Greying them says so.
    private func sweepStateChanged() {
        let armed = fader.sweep != nil
        sweepRateKey?.isHidden = !armed
        // The rate can change without the key (a saved show, a template): show it.
        sweepRateKey?.setTiming(fader.sweepRate)
        sweepCancelButton?.isHidden = !armed
        for control in manualControls { control.isEnabled = !armed }
        fader.isEnabled = true   // the fader itself stays live so the marks can be re-aimed
    }

    /// Shows or hides a button's tap-rate key to match whether it is armed.
    ///
    /// Unlike the fader's sweep, a button has no separate pair of marks — its
    /// `flipRate` IS the armed state, so the rate key drives that directly rather
    /// than a parallel flag. Walking the key down to STEP therefore disarms the
    /// button, exactly as Option-Command-clicking it a second time would; the two
    /// paths are kept in the same currency (`flipRate == nil`) rather than one using
    /// `.continuous` and the other `nil` for what reads as the same "off".
    private func wireButtonTapRate(_ button: VBOptionButton, rateKey: VBStepButton) {
        rateKey.onTimingChanged = { [weak button] timing in
            if case .continuous = timing { button?.flipRate = nil } else { button?.flipRate = timing }
        }
        button.onFlipRateChanged = { [weak self, weak button, weak rateKey] in
            guard let self, let button, let rateKey else { return }
            rateKey.isHidden = !button.isAutomated
            if let rate = button.flipRate { rateKey.setTiming(rate) }
            self.onButtonAutomationChanged?()
        }
    }

    /// The tap-rate keys float just ABOVE CUT and FADE — outside this panel's own
    /// bounds, over its header. AppKit only hit-tests a view inside its parent's
    /// bounds, so those keys were drawn but no click or right-click could reach them
    /// (found 2026-09-28 by the every-rate-key check in selfqa ui). Moving them would
    /// move controls a performer's hands are on; the PanelView routes to them instead.
    var floatingHitTargets: [NSView] { [cutRateKey, fadeRateKey, beatRateKey].compactMap { $0 } }

    /// The CUT/FADE/BEAT tap-rate keys, for checks that need to see whether arming a
    /// button revealed the right one without walking the view tree by type — there
    /// are four `VBStepButton`s on this panel (these three plus the fader's own
    /// `sweepRateKey`) and only the identity, not the type, says which is which.
    var tapRateKeysForChecks: (cut: VBStepButton?, fade: VBStepButton?, beat: VBStepButton?) {
        (cutRateKey, fadeRateKey, beatRateKey)
    }

    /// Tells the action keys which slot they belong to, so they can be learned.
    func setMappingSlot(_ slot: String) {
        cutButton?.mappingSlot = slot
        rollButton?.mappingSlot = slot
        advanceButton?.mappingSlot = slot
        fadeButton?.mappingSlot = slot
        leftKey?.mappingSlot = slot
        rightKey?.mappingSlot = slot
    }

    /// Called when this bus's blend mode changes.
    var onBlendModeChanged: ((BlendMode) -> Void)?

    /// The blend icon, whose menu pops out beside it.
    private var blendButton: VBBlendButton?

    /// Called when this bus's transition pattern changes.
    var onTransitionChanged: ((Transition) -> Void)?
    /// An ISF transition was chosen for this fader (its module id), or nil.
    var onISFTransitionChanged: ((String?) -> Void)?

    /// The pattern key on the LEFT of the transport cluster — the partner of the
    /// blend key on the right. Readable so self-QA can drive it the way a click does.
    private(set) var transitionButton: VBTransitionButton?

    /// Points the pattern key at a transition without firing its action.
    func setTransition(_ transition: Transition) {
        transitionButton?.transition = transition
    }

    /// Called, with the transition key as anchor, to open the AVE-5 wipe block.
    var onAVE5PanelRequested: ((NSView) -> Void)?

    /// Shows the AVE-5 block's state on the transition key.
    func setAVE5(_ state: AVE5Wipe) {
        transitionButton?.ave5 = state
    }
    private var leftName = ""
    private var rightName = ""

    /// - Parameters:
    ///   - leftLabel/rightLabel: the two ends, e.g. "A" and "B".
    ///   - leftColor/rightColor: bus identity colours for those ends.
    ///   - includesSwap: true for the ONE/TWO fader, which is the programme cut and
    ///     carries the extra modulation badge.
    /// - Parameters:
    ///   - leftKeyLabel/rightKeyLabel: what goes ON the bus keys. One or two
    ///     characters: switchers number their buses precisely because a key you hit
    ///     without looking has no room for a word.
    init(
        leftLabel: String, rightLabel: String,
        leftColor: NSColor, rightColor: NSColor,
        includesSwap: Bool,
        leftKeyLabel: String? = nil, rightKeyLabel: String? = nil,
        includesABRoll: Bool = false
    ) {
        self.fader = Controls.fader(value: 0.5, fillsFromCentre: true, accent: leftColor)
        fader.leadingTint = leftColor
        fader.trailingTint = rightColor
        // All three crossfaders carry the heavy track. They are the controls the
        // hands live on, and making only the programme cut thick meant A/B and C/D
        // read as lesser controls than they are — they are the same gesture, one
        // stage earlier.
        fader.trackHeightOverride = Theme.Fader.primaryTrackHeight
        super.init(frame: .zero)

        fader.target = self
        fader.action = #selector(faderMoved)

        // Broadcast language throughout, and the cut says where it is going: a button
        // labelled "Swap" tells you the mechanism; a key labelled with its source
        // tells you what is about to be on air, which is the thing that matters.
        var buttons: [NSView] = []
        // Two big keys, one per source, lit when that source is on air — the way
        // every hardwired switcher has done it. A standard push button reading
        // "CUT TO TWO" told you what would happen but looked like a web form control,
        // giving no sign that this is the most consequential thing in the window.
        // These say which source they are and light up when it is going out, which
        // is both what the button does and what you need to know.
        self.leftName = leftLabel
        self.rightName = rightLabel
        let leftKey = VBBusButton(
            label: leftKeyLabel ?? leftLabel.uppercased(), busTint: leftColor)
        leftKey.target = self
        leftKey.action = #selector(leftKeyPressed)
        leftKey.mappingCode = .cutToLeftTrigger
        leftKey.toolTip = "Cut to \(leftLabel). Shift-click to learn a MIDI button."
        let rightKey = VBBusButton(
            label: rightKeyLabel ?? rightLabel.uppercased(), busTint: rightColor)
        rightKey.target = self
        rightKey.action = #selector(rightKeyPressed)
        rightKey.mappingCode = .cutToRightTrigger
        rightKey.toolTip = "Cut to \(rightLabel). Shift-click to learn a MIDI button."
        self.leftKey = leftKey
        self.rightKey = rightKey
        buttons.append(leftKey)
        buttons.append(rightKey)
        // CUT. Asked for repeatedly and genuinely absent: the bus keys cut TO a named
        // source, but there was no single key that simply takes the other one — which
        // is the most basic thing a vision mixer does, and the one you reach for
        // without looking. On all three faders.
        let cutButton = VBOptionButton(title: "CUT", onColour: Theme.Color.tallyOnAir)
        cutButton.target = self
        cutButton.action = #selector(cutPressed)
        cutButton.toolTip = "Cut straight to the other source. "
            + "With Beat on, it waits for the next beat. Shift-click to learn a MIDI button."
        cutButton.mappingCode = .cutTrigger
        cutButton.isTall = true
        self.cutButton = cutButton
        buttons.append(cutButton)

        // Option-Command arms CUT to tap on the beat instead of once — the same
        // gesture that marks a fader sweep, turned into a strobe cut since a button
        // has no span to travel between. The rate key that appears is the
        // crossfader's `sweepKey` again, on the SAME ladder: click for faster,
        // right-click (or Control-click) for slower.
        let cutRateKey = VBStepButton()
        cutRateKey.allowsOff = false     // a rate key never walks to off (VBStepButton)
        cutRateKey.isHidden = true
        cutRateKey.toolTip = "How often CUT taps while armed. "
            + "Option-Command-click CUT to arm or disarm it."
        self.cutRateKey = cutRateKey
        // FLOATS above CUT rather than sitting in the row at all — positioned with
        // its own constraints (see below), not appended to `buttons`. The row's
        // height must not depend on whether a button happens to be armed: a
        // performer's hand is on these keys, and a row that grows and pushes
        // everything below it down the instant one arms would move CUT/FADE/BEAT
        // out from under the fingers that were just about to hit them.

        // Fade and Beat are instrument keys now, not bezelled push buttons. They sat
        // next to the flat bus keys looking like controls from a settings dialogue,
        // and at .small they were the smallest things in a row you hit by feel.
        let fadeButton = VBOptionButton(title: "FADE")
        fadeButton.target = self
        fadeButton.action = #selector(fadePressed)
        fadeButton.toolTip = "Fade to the other source over the time set by the "
            + "turtle/rabbit control. Shift-click to learn a MIDI button."
        fadeButton.mappingCode = .fadeTrigger
        fadeButton.isTall = true
        self.fadeButton = fadeButton
        buttons.append(fadeButton)

        // Same gesture on FADE — a fade that repeats on the beat rather than firing
        // once.
        let fadeRateKey = VBStepButton()
        fadeRateKey.allowsOff = false
        fadeRateKey.isHidden = true
        fadeRateKey.toolTip = "How often FADE taps while armed. "
            + "Option-Command-click FADE to arm or disarm it."
        self.fadeRateKey = fadeRateKey

        // Cut-on-beat. With this on, a cut waits for the next subdivision and is
        // taken early by the graph's latency so the picture changes ON the beat.
        let beatToggle = VBOptionButton(title: "BEAT")
        beatToggle.target = self
        beatToggle.action = #selector(beatCutPressed)
        // Beat answers WHEN, not WHAT. With it on, a bus key still cuts and Fade
        // still fades — they just wait for the next boundary first.
        beatToggle.toolTip = "Hold the next cut or fade until the beat. "
            + "Which beat is set by DIV in the transport readout."
        beatToggle.isTall = true
        self.beatCutButton = beatToggle
        // BEAT is off the panel for now (owner, 2026-09-27: "I don't know if this will
        // be useful for anyone"). Still built and wired — cut-on-beat stays OFF unless
        // something sets it — so bringing it back is appending it to `buttons` again.

        // And on BEAT itself — flips whether the next cut/fade waits, on the beat.
        let beatRateKey = VBStepButton()
        beatRateKey.allowsOff = false
        beatRateKey.isHidden = true
        beatRateKey.toolTip = "How often BEAT taps while armed. "
            + "Option-Command-click BEAT to arm or disarm it."
        self.beatRateKey = beatRateKey

        wireButtonTapRate(cutButton, rateKey: cutRateKey)
        wireButtonTapRate(fadeButton, rateKey: fadeRateKey)
        wireButtonTapRate(beatToggle, rateKey: beatRateKey)

        // The rate control: three positions, turtle to rabbit. A performance wants
        // "slow" without choosing a number, and the exact seconds matter far less
        // than the feel — which is why this is not a continuous slider.
        // SF Symbols rather than emoji. An emoji is a full-colour glyph rendered by
        // the system font — it cannot be tinted, it does not match the flat monochrome
        // language of every other key in this row, and it renders differently across
        // OS versions. These are real icons and take the control's own colour.
        let rateSymbols = [
            ("tortoise.fill", "Slow fade"),
            ("minus", "Medium fade"),
            ("hare.fill", "Fast fade")
        ]
        let rateImages: [NSImage] = rateSymbols.compactMap {
            guard let image = NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1)
            else { return nil }
            image.isTemplate = true
            return image
        }
        // A slide toggle rather than a segmented control. A rate HAS A POSITION — slow,
        // middle, fast — and a knob that travels to it says that; three cells that take
        // turns lighting up say "three buttons that happen to be touching". It is also
        // the only way to get this the same height as CUT, FADE and BEAT: AppKit's
        // rounded segmented bezel is fixed-height and centres itself in whatever frame
        // a constraint gives it, which is why the first two attempts stayed short.
        let rateControl = VBSlideToggle(
            images: rateImages, tooltips: rateSymbols.map(\.1), selected: 1)
        rateControl.target = self
        rateControl.action = #selector(rateChanged(_:))
        // Narrower positions, same height: room for ROLL and ADV in the row.
        rateControl.cellWidth = 18
        rateControl.heightAnchor.constraint(
            equalToConstant: Theme.BusButton.height).isActive = true
        self.rateControl = rateControl
        // No mapping badges here. They were decoration — unclickable letters wired to
        // nothing — and one of them read "Slo", which was not an abbreviation of
        // anything. Shift-click the fader to map it; that gesture reaches every fader
        // in the window and does not cost a column of the shortest panel in the grid.
        // BLEND, moved here from the preview above. How the two layers combine and
        // how much of each are two halves of one question; having them two panels
        // apart meant answering it in two places.
        // A square A/B icon that pops its menu out, not a popup as wide as "Color
        // Dodge". The word does not need to be on screen at all times, and the popup's
        // width was what shoved the transport cluster off centre and still truncated
        // to "No…".
        let blend = VBBlendButton()
        // The bus's own letters, not a hard-coded A and B: this same panel is the A/B
        // fader, the C/D fader and the programme fader.
        blend.setLabels(lower: leftLabel, upper: rightLabel)
        blend.onModeChosen = { [weak self] mode in
            Log.info(.graph, "blend mode set to \(mode.displayName)")
            self?.onBlendModeChanged?(mode)
        }
        self.blendButton = blend

        // TRANSITION, the left-hand partner of BLEND: blend says how the layers
        // combine, this says what shape the move takes. It sits opposite the blend
        // key, out at the leading edge, because it is a setting like blend and not a
        // performance key — but a setting you change between moves, so the pictogram
        // on the key shows which pattern is armed without opening anything.
        let transitionKey = VBTransitionButton()
        transitionKey.onTransitionChosen = { [weak self] transition in
            Log.info(.graph, "transition set to \(transition.displayName)")
            self?.onTransitionChanged?(transition)
        }
        transitionKey.onAVE5PanelRequested = { [weak self] anchor in
            self?.onAVE5PanelRequested?(anchor)
        }
        transitionKey.onISFTransitionChosen = { [weak self] id in
            Log.info(.graph, "ISF transition set to \(id ?? "none")")
            self?.onISFTransitionChanged?(id)
        }
        self.transitionButton = transitionKey

        // The crossfader's own sweep controls, exactly as an FX row has them — this
        // panel had the gesture and the yellow bar but no way to set the rate or to
        // stop it, which made an armed crossfader a thing you could start and not
        // steer.
        let sweepKey = VBStepButton()
        sweepKey.allowsOff = false
        sweepKey.isHidden = true
        sweepKey.toolTip = "How long one sweep between the marks takes"
        self.sweepRateKey = sweepKey

        let sweepCancel = Controls.glyphButton("✕", tooltip: "Stop this fader driving itself")
        sweepCancel.isHidden = true
        sweepCancel.target = fader
        sweepCancel.action = #selector(VBFader.clearSweep)
        self.sweepCancelButton = sweepCancel
        // AUTO is gone rather than left sitting there disabled. It was never
        // implemented, and it could not be without duplicating something: on a vision
        // mixer AUTO performs the transition at the set rate, which is exactly what
        // FADE already does with the turtle/rabbit control beside it. A permanently
        // dead key that would duplicate its neighbour is worse than no key.
        sweepKey.onTimingChanged = { [weak self] timing in
            self?.fader.sweepRate = timing
        }
        sweepKey.setTiming(fader.sweepRate)
        fader.onSweepChanged = { [weak self] in
            self?.sweepStateChanged()
            self?.onSweepChanged?()
        }

        // ── The transport cluster, centred ──────────────────────────────────────
        //
        // CUT, FADE, BEAT and the rate control are ONE thing: the four keys a hand
        // reaches for during a transition. Left-aligned in a row that also carried
        // BLEND and the sweep keys, they read as the first four of seven unrelated
        // controls. Grouped and centred they read as the instrument they are, and the
        // panel has a middle again.
        //
        // `buttons` still holds CUT, FADE and BEAT in order; the rate joins them here.
        if includesABRoll {
            let roll = VBOptionButton(title: "ROLL")
            roll.target = self
            roll.action = #selector(rollPressed(_:))
            roll.mappingCode = .rollToggleTrigger
            roll.toolTip = "A/B ROLL: the source you take rolls (plays) as it goes on air; "
                + "the one leaving pauses and re-cues to its start. Shift-click to learn a MIDI button."
            roll.setAccessibilityIdentifier("ab-roll")
            let advance = VBOptionButton(title: "ADV")
            advance.target = self
            advance.action = #selector(advancePressed(_:))
            advance.mappingCode = .advanceToggleTrigger
            advance.toolTip = "ADV: the source leaving air loads its next clip — Up Next first, "
                + "then the library (Settings ▸ Defaults). Shift-click to learn a MIDI button."
            advance.setAccessibilityIdentifier("ab-advance")
            roll.isTall = true
            advance.isTall = true
            rollButton = roll
            advanceButton = advance
            // In the performance row, after FADE: same size as CUT and FADE, reached
            // the same way (owner, 2026-09-27).
            buttons.append(contentsOf: [roll, advance])
        }
        let transportCluster = Controls.row(buttons + [rateControl], spacing: 4)
        transportCluster.translatesAutoresizingMaskIntoConstraints = false

        // BLEND and the fader's OWN sweep keys are settings, not performance keys, so
        // they sit out at the trailing edge rather than inside the cluster — there is
        // exactly one fader per panel, so "off in the corner" still reads as
        // belonging to it. The three button tap-rate keys do NOT join them: CUT,
        // FADE and BEAT can each be armed independently, and a rate key stranded
        // here with two others would not say which button it belongs to. Each lives
        // in `buttons`, right beside its own key, instead (see above).
        // ROLL and ADV (sub-mix faders only, `FeatureFlag.abRoll`) are made here and
        // join the performance row above, after FADE.
        let options: [NSView] = [blend, sweepKey, sweepCancel]
        let optionsRow = Controls.row(options, spacing: 4)
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        // Both live in a band so the cluster can be centred on the PANEL while the
        // options stay pinned right. Centring is priority 750 on purpose: when the
        // panel is too narrow for both, the cluster gives way and slides left rather
        // than the two overlapping.
        let buttonRow = NSView()
        buttonRow.addSubview(transportCluster)
        buttonRow.addSubview(optionsRow)
        buttonRow.addSubview(transitionKey)

        let centring = transportCluster.centerXAnchor.constraint(
            equalTo: buttonRow.centerXAnchor)
        centring.priority = .defaultHigh
        NSLayoutConstraint.activate([
            transportCluster.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            transportCluster.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            transportCluster.leadingAnchor.constraint(
                greaterThanOrEqualTo: transitionKey.trailingAnchor, constant: 8),
            transportCluster.trailingAnchor.constraint(
                lessThanOrEqualTo: optionsRow.leadingAnchor, constant: -8),
            centring,

            optionsRow.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            optionsRow.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),

            transitionKey.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            transitionKey.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
            buttonRow.heightAnchor.constraint(equalTo: transportCluster.heightAnchor)
        ])

        let left = Controls.label(leftLabel, font: Theme.Font.tinyLabel, color: leftColor,
                                  holdsWidth: true)
        let right = Controls.label(rightLabel, font: Theme.Font.tinyLabel, color: rightColor,
                                   holdsWidth: true)
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        fader.translatesAutoresizingMaskIntoConstraints = false

        // The crossfader is the panel's main control, so it gets the full width and
        // more height than a parameter fader — it is the one a hand reaches for
        // without looking. Everything else arranges around it rather than competing
        // with it for width, which is what squeezed it to nothing before.
        addSubview(left)
        addSubview(right)
        addSubview(fader)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            // The band spans the panel, so "centred" means centred in the PANEL
            // rather than centred in whatever width the controls happened to need.
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            // End labels and the live value sit on one line above the fader. The
            // gaps are tight because this panel is the shortest in the grid (row
            // weight 0.6) and the content has to fit at the compact breakpoint —
            // anything looser and the rows overlap instead of just being close.
            left.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 3),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),


            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            // The fader spans the panel.
            fader.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 2),
            fader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            fader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            fader.heightAnchor.constraint(equalToConstant: Theme.Fader.crossfaderHeight),
            fader.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding)
        ])

        // The tap-rate keys float over their buttons, outside every stack view, so
        // showing one never changes the row's size or moves a key under a finger.
        for (rateKey, button) in [(cutRateKey, cutButton), (fadeRateKey, fadeButton)] as [(VBStepButton, NSView)] {
            rateKey.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rateKey)
            NSLayoutConstraint.activate([
                rateKey.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                rateKey.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -2)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Moves the fader programmatically (from a MIDI mapping or a scheduled cut).
    func setPosition(_ position: Double) {
        fader.value = position
        valueLabel.stringValue = String(format: "%.2f", position)
        updateCutLabel()
    }

    @objc private func faderMoved() {
        valueLabel.stringValue = String(format: "%.2f", fader.value)
        updateCutLabel()
        onFaderMoved?(fader.value)
    }

    @objc private func fadePressed() {
        onFade?(currentRate)
    }

    /// Cuts straight to whichever source is not currently up.
    @objc private func cutPressed() {
        onCutRequested?()
    }

    @objc private func rollPressed(_ sender: VBOptionButton) {
        onRollToggled?(sender.isOn)
    }

    @objc private func advancePressed(_ sender: VBOptionButton) {
        onAdvanceToggled?(sender.isOn)
    }

    /// Shows ROLL's state (a MIDI toggle, a template) without firing it.
    func setRoll(on: Bool) { rollButton?.isOn = on }
    /// Shows ADV's state without firing it.
    func setAdvance(on: Bool) { advanceButton?.isOn = on }

    @objc private func beatCutPressed(_ sender: NSButton) {
        sender.contentTintColor = sender.state == .on ? Theme.Color.accent : nil
        onBeatCutToggled?(sender.state == .on)
    }

    @objc private func rateChanged(_ sender: VBSlideToggle) {
        Log.info(.app, "fade rate: \(currentRate.displayName)")
    }

    /// The rate the three-position control is set to. Readable from outside so a
    /// MIDI-fired FADE uses the same rate a clicked one would, rather than the
    /// controller keeping a second copy that can drift.
    var currentRate: FadeRate {
        FadeRate.from(index: rateControl?.selectedIndex ?? 1)
    }

    @objc private func leftKeyPressed() { cut(to: 0) }
    @objc private func rightKeyPressed() { cut(to: 1) }

    /// Fires as if the left/right bus key were pressed — used when a MIDI-mapped
    /// button pushes `cutToLeftTrigger`/`cutToRightTrigger` to 1 (SPEC 7).
    /// Presses BEAT on or off exactly as a click does — for self-QA.
    func setBeatForChecks(_ on: Bool) {
        guard let beat = beatCutButton, beat.isOn != on else { return }
        beat.isOn = on
        onBeatCutToggled?(on)
    }

    /// Where the crossfader is drawn — for self-QA.
    var faderValueForChecks: Double { fader.value }

    /// Shows a blend mode set from outside (a template load) without firing it.
    func setBlendModeForTemplate(_ mode: BlendMode) {
        blendButton?.mode = mode
    }

    func triggerLeftKey() { cut(to: 0) }
    func triggerRightKey() { cut(to: 1) }

    /// Takes a source to air.
    ///
    /// A named destination rather than "the other end": pressing the key for what is
    /// already on air is a no-op on a real switcher, not a cut back to the other
    /// source, and guessing from the fader's position is how you get a cut you did
    /// not ask for.
    private func cut(to target: Double) {
        guard abs(fader.value - target) > 0.001 else { return }
        setPosition(target)
        onFaderMoved?(target)
        onCutTo?(target)
    }

    /// Lights each key by how much of the picture its source currently is.
    private func updateCutLabel() {
        leftKey?.onAirAmount = 1.0 - fader.value
        rightKey?.onAirAmount = fader.value
    }
}
