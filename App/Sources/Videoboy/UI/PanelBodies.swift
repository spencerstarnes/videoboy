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

    /// This source's fill key.
    private weak var fillKey: VBOptionButton?

    /// How this source's picture fills its window.
    private var previewFill: PreviewFill = .fit {
        didSet {
            preview.fillMode = previewFill
            fillKey?.setTitle(previewFill.displayName.uppercased())
        }
    }

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

    /// Switches this channel to a generator, or back to its file.
    /// A nil kind means "go back to the file".
    var onGeneratorSelected: ((GeneratorKind?) -> Void)?

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
        guard droppedURL(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let clip = droppedClip(from: sender) else { return false }
        onClipDropped?(clip.url, clip.range)
        return true
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
        self.preview = MetalPreviewView(caption: channel, recordLabel: channel)
        super.init(frame: .zero)

        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        // Accepts clips dragged from a library AND files dragged from the Finder.
        // The same type, so there is one drop path rather than a private one for the
        // library that would work while the obvious gesture did not.
        registerForDraggedTypes([.fileURL])

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

        // A generator is an alternative source for the channel, not a separate panel:
        // SPEC 6A says generators are selectable anywhere A/B/C/D.
        let generatorPopUp = Controls.popUp(
            ["File"] + GeneratorKind.allCases.map(\.displayName),
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
        let fillKey = VBOptionButton(title: PreviewFill.fit.displayName.uppercased())
        fillKey.toolTip = "How this source's picture fills its window. Click to cycle."
        fillKey.target = self
        fillKey.action = #selector(fillCycled)
        self.fillKey = fillKey

        let sourceRow = Controls.row([load, generatorPopUp, stepButton, fillKey, Controls.spacer()],
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

    func setScrubPosition(_ position: Double) {
        scrubFader?.value = position
        // The resting line reads the same playhead as the shuttle's track, so the
        // two never disagree about where the clip is when hovering swaps them.
        miniPlayBar?.progress = position
    }

    @objc private func generatorChanged(_ sender: NSPopUpButton) {
        // Item 0 is "File"; the rest are the generator kinds in order.
        let index = sender.indexOfSelectedItem
        guard index > 0, index - 1 < GeneratorKind.allCases.count else {
            onGeneratorSelected?(nil)
            return
        }
        onGeneratorSelected?(GeneratorKind.allCases[index - 1])
    }
}

// MARK: - Preview-only panels

/// Sub Mix ONE / TWO / Program: a large 4:3 preview, optionally with the blend
/// controls for the composite it represents (SPEC 14.2).
final class PreviewPanelBody: NSView {

    let preview: MetalPreviewView

    /// Called when the blend mode changes, with the chosen mode.
    var onBlendModeChanged: ((BlendMode) -> Void)?

    /// Called when the bus's interchange codec changes.
    var onInterchangeChanged: ((InterchangeCodec) -> Void)?
    /// Called when a bus data-effect parameter moves: (param code, 0...1).
    var onDataParameterChanged: ((String, Double) -> Void)?

    /// Called when the scope tab is clicked, to advance the scope cycle.
    var onScopeTabClicked: (() -> Void)?

    /// The scope tab, so its title can show the current mode.
    private var scopeTab: NSButton?
    private var blendPopUp: NSPopUpButton?
    private var interchangePopUp: NSPopUpButton?
    private var dataEffectRow: NSStackView?
    /// The bus data-effect faders, exposed so the shell can address them for MIDI.
    private(set) var dataAmountFader: VBFader?
    private(set) var dataModeFader: VBFader?

    /// - Parameter showsBlendControls: true for the composites that carry a blend
    ///   mode — the two sub-mixes and the program.
    init(caption: String, showsBlendControls: Bool = false, recordLabel: String? = nil) {
        self.preview = MetalPreviewView(caption: caption, recordLabel: recordLabel)
        super.init(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        var bottomAnchorTarget = bottomAnchor
        var bottomConstant: CGFloat = -2

        if showsBlendControls {
            // BLEND moved to the fader panel beneath this one. It decides how the two
            // layers combine, and the crossfader decides how much of each — they are
            // two halves of one question, and they were two panels apart.

            // The bus interchange codec. A mixed bus is a texture with no bitstream,
            // so data effects on it are only possible if it is re-encoded first —
            // this popup is that choice, and it decides which data effects appear.
            let interchange = Controls.popUp(
                InterchangeCodec.allCases.map(\.displayName),
                target: self, action: #selector(interchangeChanged(_:))
            )
            interchangePopUp = interchange

            // The scope tab. One control that cycles every scope view, so reaching a
            // vectorscope is never more than a few clicks and never a menu.
            let scopes = Controls.button("Scopes", target: self, action: #selector(scopeTabPressed))
            scopes.toolTip = "Cycle the scopes: quad overlay, histogram, parade, quad over black, off"
            scopeTab = scopes

            let row = Controls.row([
                Controls.label("Data", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                interchange,
                Controls.spacer(),
                scopes
            ], spacing: 4)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            // The bus data-effect controls, hidden until an interchange is chosen.
            // Hidden rather than disabled: with no interchange there is no bitstream,
            // so these are not "not yet built", they are meaningless.
            let dataAmount = Controls.fader(
                value: 0, compact: true, accent: Theme.Color.recordActive,
                target: self, action: #selector(dataAmountChanged(_:)))
            let dataMode = Controls.fader(
                value: 0, compact: true, accent: Theme.Color.recordActive,
                target: self, action: #selector(dataModeChanged(_:)))
            dataAmountFader = dataAmount
            dataModeFader = dataMode
            let dataRow = Controls.row([
                Controls.label("dmg", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                dataAmount,
                Controls.label("mode", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                dataMode
            ], spacing: 4)
            dataRow.translatesAutoresizingMaskIntoConstraints = false
            dataRow.isHidden = true
            addSubview(dataRow)
            dataEffectRow = dataRow

            NSLayoutConstraint.activate([
                dataRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                dataRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                dataRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                row.bottomAnchor.constraint(equalTo: dataRow.topAnchor, constant: -2)
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

    @objc private func scopeTabPressed() { onScopeTabClicked?() }

    /// Updates the tab's title to name the mode it is now in.
    func setScopeMode(_ mode: ScopeDisplayMode) {
        scopeTab?.title = mode == .off ? "Scopes" : mode.displayName
        scopeTab?.contentTintColor = mode == .off ? nil : Theme.Color.accent
    }

    @objc private func interchangeChanged(_ sender: NSPopUpButton) {
        let codec = InterchangeCodec.allCases[
            min(sender.indexOfSelectedItem, InterchangeCodec.allCases.count - 1)]
        // The data controls only exist when there is a bitstream for them to act on.
        dataEffectRow?.isHidden = (codec == .none)
        Log.info(.bitstream, "bus interchange set to \(codec.displayName)")
        onInterchangeChanged?(codec)
    }

    @objc private func dataAmountChanged(_ sender: VBFader) {
        onDataParameterChanged?(ParamCode.corruptAmount.rawValue, sender.value)
    }

    @objc private func dataModeChanged(_ sender: VBFader) {
        onDataParameterChanged?(ParamCode.corruptMode.rawValue, sender.value)
    }

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        let mode = BlendMode.allCases[min(sender.indexOfSelectedItem, BlendMode.allCases.count - 1)]
        Log.info(.graph, "blend mode set to \(mode.displayName)")
        onBlendModeChanged?(mode)
    }

}

// MARK: - Faders

/// A crossfader panel: Cut, Fade, cut-on-beat, Auto, mapping badges, the fader
/// itself and its numeric value (SPEC 14.2).
final class FaderPanelBody: NSView {

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
    private var rateControl: NSSegmentedControl?

    /// Called when CUT is pressed: take the other source, now.
    var onCutRequested: (() -> Void)?

    /// Called when this bus's blend mode changes.
    var onBlendModeChanged: ((BlendMode) -> Void)?

    private var blendPopUp: NSPopUpButton?

    /// Points the popup at a mode without firing its action.
    func setBlendMode(_ mode: BlendMode) {
        blendPopUp?.selectItem(at: min(mode.rawValue, (blendPopUp?.numberOfItems ?? 1) - 1))
    }

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        let modes = BlendMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        onBlendModeChanged?(modes[sender.indexOfSelectedItem])
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
        leftKeyLabel: String? = nil, rightKeyLabel: String? = nil
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
        let rightKey = VBBusButton(
            label: rightKeyLabel ?? rightLabel.uppercased(), busTint: rightColor)
        rightKey.target = self
        rightKey.action = #selector(rightKeyPressed)
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
            + "With Beat on, it waits for the next beat."
        buttons.append(cutButton)

        // Fade and Beat are instrument keys now, not bezelled push buttons. They sat
        // next to the flat bus keys looking like controls from a settings dialogue,
        // and at .small they were the smallest things in a row you hit by feel.
        let fadeButton = VBOptionButton(title: "FADE")
        fadeButton.target = self
        fadeButton.action = #selector(fadePressed)
        fadeButton.toolTip = "Fade to the other source over the time set by the "
            + "turtle/rabbit control"
        buttons.append(fadeButton)

        // Cut-on-beat. With this on, a cut waits for the next subdivision and is
        // taken early by the graph's latency so the picture changes ON the beat.
        let beatToggle = VBOptionButton(title: "BEAT")
        beatToggle.target = self
        beatToggle.action = #selector(beatCutPressed)
        // Beat answers WHEN, not WHAT. With it on, a bus key still cuts and Fade
        // still fades — they just wait for the next boundary first.
        beatToggle.toolTip = "Hold the next cut or fade until the beat. "
            + "Which beat is set by DIV in the transport readout."
        self.beatCutButton = beatToggle
        buttons.append(beatToggle)

        // The rate control: three positions, turtle to rabbit. A performance wants
        // "slow" without choosing a number, and the exact seconds matter far less
        // than the feel — which is why this is not a continuous slider.
        let rateControl = Controls.segmented(
            ["🐢", "•", "🐇"], selected: 1, target: self, action: #selector(rateChanged(_:)))
        rateControl.setToolTip("Slow fade", forSegment: 0)
        rateControl.setToolTip("Medium fade", forSegment: 1)
        rateControl.setToolTip("Fast fade", forSegment: 2)
        self.rateControl = rateControl
        buttons.append(rateControl)
        // No mapping badges here. They were decoration — unclickable letters wired to
        // nothing — and one of them read "Slo", which was not an abbreviation of
        // anything. Shift-click the fader to map it; that gesture reaches every fader
        // in the window and does not cost a column of the shortest panel in the grid.
        // BLEND, moved here from the preview above. How the two layers combine and
        // how much of each are two halves of one question; having them two panels
        // apart meant answering it in two places.
        let blend = Controls.popUp(
            BlendMode.allCases.map(\.displayName),
            target: self, action: #selector(blendModeChanged(_:)))
        blend.toolTip = "How this bus's two layers combine. The fader below sets how much of each."
        self.blendPopUp = blend
        buttons.append(blend)

        buttons.append(Controls.spacer())
        // AUTO is gone rather than left sitting there disabled. It was never
        // implemented, and it could not be without duplicating something: on a vision
        // mixer AUTO performs the transition at the set rate, which is exactly what
        // FADE already does with the turtle/rabbit control beside it. A permanently
        // dead key that would duplicate its neighbour is worse than no key.
        let buttonRow = Controls.row(buttons, spacing: 4)

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
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),

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

    @objc private func beatCutPressed(_ sender: NSButton) {
        sender.contentTintColor = sender.state == .on ? Theme.Color.accent : nil
        onBeatCutToggled?(sender.state == .on)
    }

    @objc private func rateChanged(_ sender: NSSegmentedControl) {
        Log.info(.app, "fade rate: \(currentRate.displayName)")
    }

    /// The rate the three-position control is set to.
    private var currentRate: FadeRate {
        FadeRate.from(index: rateControl?.selectedSegment ?? 1)
    }

    @objc private func leftKeyPressed() { cut(to: 0) }
    @objc private func rightKeyPressed() { cut(to: 1) }

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
