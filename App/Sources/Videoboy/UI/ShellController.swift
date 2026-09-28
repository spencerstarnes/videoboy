//
//  ShellController.swift — wires the window's controls to the engine.
//
//  Purpose : The one place where a click becomes an action. Views stay dumb and the
//            engine stays UI-free; this is the seam between them. It also pushes
//            state the other way each frame — previews, readouts, status.
//  Inputs  : user actions from the panels; a frame callback from the engine.
//  Outputs : engine calls, and refreshed views.
//  Connects: Engine, ShellView and its panels, OutputWindowController.
//  Extend  : wire a new control here. Do not give a view a reference to the engine.
//

import AppKit
import VideoboyCore

/// Connects the shell's views to the engine.
final class ShellController {

    let shell: ShellView
    private let engine: Engine
    private let preferences: PreferenceStore
    /// Live sessions for whatever configured sources (SPEC 6, SPEC 10) are actually
    /// running right now — a subset of `preferences.preferences.configuredSources`,
    /// since a source exists the moment it is added in Settings but its session only
    /// starts when a channel is actually pointed at it.
    private let sourceSessions = SourceSessionManager()
    private var outputWindow: OutputWindowController?
    /// Everything leaving the app beyond the PROGRAM output window.
    private lazy var router = OutputRouter(store: preferences, metal: MetalContext.shared)
    /// Shift-to-detect. Exposed so the self-QA render can arm it.
    private(set) var detectSession: DetectSession?
    /// The control a MIDI learn is armed for, until a message maps it or it is
    /// cancelled (Esc) or cleared (⌫) — what the learn keys act on.
    private(set) var pendingLearn: (slot: String, code: ParamCode)?
    private var learnKeyMonitor: Any?
    /// The top bar's Clip Pads (docs/specs/clip-pads.md).
    private(set) var clipPads: ClipPadController?

    /// The AVE-5 wipe block's popover, while one is open, and the bus it edits.
    /// One at a time: it is opened from a fader's key, and a second fader's block
    /// replaces the first rather than stacking up over the window.
    private(set) var ave5Popover: NSPopover?
    private(set) var ave5Panel: AVE5WipePanelController?
    /// What each bus's transition key last drew, so the per-frame refresh redraws
    /// only on a change.
    private var ave5OnKeys: [String: AVE5Wipe] = [:]

    /// Channel letters in the order their previews appear.
    private static let channels = ["A", "B", "C", "D"]

    init(shell: ShellView, engine: Engine, preferences: PreferenceStore = PreferenceStore()) {
        self.shell = shell
        self.engine = engine
        self.preferences = preferences
        wireSources()
        wireFaders()
        wireSeamSwapKeys()
        wireBlendControls()
        wireDataBurn()
        wireEffectChains()
        wireToolbar()
        wireSettingsBar()
        wireRecordIndicators()
        wireEmulator()
        wireLibraries()
        refreshPlaylists()
        wireRouting()
        setPreviewFill(preferences.preferences.previewFill)
        // No single default camera to start here any more — a configured source's
        // session starts when a channel is actually pointed at it (`assignSource`),
        // the same as a file only starts decoding once it is loaded into one.
        // Before Detect, so the pads' codes are registered when Shift first looks.
        clipPads = ClipPadController(shell: self, engine: engine, toolbar: shell.toolbar)
        // HOT PUNCH starts as Settings ▸ Defaults says (off unless chosen).
        clipPads?.setHotPunchArmed(preferences.preferences.hotPunchArmedAtLaunch)
        wireDetect()
        refreshDrivenParameters()
        engine.onTempoChanged = { [weak self] tempo in
            self?.shell.flashTempoChange()
            self?.shell.toolbar.setTempo(tempo)
        }
        engine.onBeatReport = { [weak self] report in self?.showBeatReport(report) }
        engine.onBeforeRender = { [weak self] engine in self?.advanceAutomation(from: engine) }
        engine.onFrame = { [weak self] engine in self?.refresh(from: engine) }
    }

    /// Moves every automated fader to where it should be in the frame about to render.
    ///
    /// Sampled at the frame's PRESENTATION time, before it renders — not after the
    /// previous one at whatever moment that finished. The fader is then exactly on
    /// its curve in every frame, so a push or slide travels by an even step.
    private func advanceAutomation(from engine: Engine) {
        let showAt = engine.framePresentationTime
        updateFadesAndCuts(at: showAt)
        driveSweeps(from: engine, at: showAt)
    }

    /// `loadClip`, for self-QA: the real path, so a check proves what a drop does.
    func loadClipForChecks(_ url: URL, into channel: String) {
        loadClip(url, into: channel)
    }

    /// Loads a clip into a channel and says what happened.
    ///
    /// The single path for every way a file arrives — double-clicked in a library,
    /// dragged onto a source, or chosen from the Load button — so a file that loads
    /// one way cannot silently fail another.
    ///
    /// Opening happens OFF the main thread (`Engine.loadAsync`, audit F9): the channel
    /// keeps showing what it had until the new clip is ready, then everything below
    /// runs. `then` is told whether it loaded, after the panel is updated.
    func loadClip(
        _ url: URL, into channel: String, range: ClosedRange<Double>? = nil,
        then: ((Bool) -> Void)? = nil
    ) {
        // Linked optimized media plays in place of the original when there is one for
        // this canvas (Settings ▸ Optimize; a missing file falls back to the original).
        let library = shell.grid.panels.library
        let playing = preferences.preferences.usesOptimizedMedia
            ? library.playbackURL(for: url, canvas: ClipOptimizer.canvasTag) : (url: url, optimized: false)
        let known = playing.optimized ? nil : library.frameCount(forPath: url.path)
        engine.loadAsync(url: playing.url, intoChannel: channel, knownFrameCount: known) { [weak self] loaded in
            self?.clipLoaded(url, into: channel, range: range, loaded: loaded)
            then?(loaded)
        }
    }

    /// The main-thread half of `loadClip`, once the clip is open (or failed to).
    func clipLoaded(_ url: URL, into channel: String, range: ClosedRange<Double>?, loaded: Bool) {
        guard loaded else {
            presentNotice(
                "Could not load \(url.lastPathComponent)",
                "The file could not be opened. It may use a codec macOS cannot "
                    + "read, or have no video track."
            )
            return
        }
        engine.sources[channel]?.playbackRange = range
        returnChannelToFile(channel)
        // The marks go on the play bar, so a trimmed clip LOOKS trimmed. A clip that
        // looks identical whether or not it has in and out points is how those points
        // come to seem broken.
        shell.grid.panels.sourceBodies[channel]?.setMarkedRange(range)
        shell.grid.panels.sourceBodies[channel]?.setMediaName(
            range == nil
                ? url.lastPathComponent
                : "\(url.lastPathComponent) [trimmed]")
        // Read the timing back off the node rather than assuming it. Loading decides it
        // now — a folder of photographs arrives stepped to the beat (SPEC §153) while a
        // video file stays continuous — so the STEP key is told what actually happened.
        if let timing = engine.sources[channel]?.timing {
            shell.grid.panels.sourceBodies[channel]?.setTiming(timing)
        }
        // The channel's own checkbox wins; the preference is only what a fresh
        // channel starts out agreeing with.
        if autoPlayByChannel[channel] ?? preferences.preferences.playOnLoad {
            engine.setPlaying(true, channel: channel)
        }
        Log.info(.clip, "loaded \(url.lastPathComponent) into channel \(channel)")
    }

    /// One up-next queue per source (A, B, C, D).
    ///
    /// Only consulted when a source is in ONE SHOT — see `Playlist`. Loop and
    /// ping-pong have their own answer for what happens at the end of a clip.
    private var playlists = PlaylistSet()

    /// Pushes the queues back into whichever library shows them.
    private func refreshPlaylists() {
        // A queue edit can change ADV's next clip: plan (and pre-open) again.
        if advanceOn.values.contains(true) { replanAdvance() }
        refreshPlaylistViews()
    }

    private var playlistChannelsToRefresh: Set<String> = []

    /// Redraws one channel's Up Next list on the next run-loop turn (coalesced).
    private func schedulePlaylistViewRefresh(_ channel: String) {
        let first = playlistChannelsToRefresh.isEmpty
        playlistChannelsToRefresh.insert(channel)
        guard first else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            let channels = self.playlistChannelsToRefresh
            self.playlistChannelsToRefresh = []
            let panels = self.shell.grid.panels
            for channel in channels {
                let panel = ["A", "B"].contains(channel) ? panels.libraryOneBody : panels.libraryTwoBody
                panel.setPlaylist(self.playlists[channel], forChannel: channel)
            }
        }
    }

    private func refreshPlaylistViews() {
        let panels = shell.grid.panels
        for channel in ["A", "B"] {
            panels.libraryOneBody.setPlaylist(playlists[channel], forChannel: channel)
        }
        for channel in ["C", "D"] {
            panels.libraryTwoBody.setPlaylist(playlists[channel], forChannel: channel)
        }
    }

    /// A one-shot clip finished. Pull the next thing off that channel's queue, if
    /// there is one; otherwise leave the source stopped on its last frame exactly as
    /// it behaved before playlists existed.
    ///
    /// Hops to the main queue first: this arrives from the playback advance, and it
    /// is about to open a file and touch the panel.
    private func playlistAdvance(channel: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let next = self.playlists[channel].takeNext() else { return }
            Log.info(.clip, "\(channel) taking \(next.displayName) from its playlist")
            self.loadClip(next.url, into: channel) { [weak self] loaded in
                // Up next means up NEXT — it plays, rather than landing paused and
                // waiting for someone to notice the clip changed.
                if loaded { self?.engine.setPlaying(true, channel: channel) }
            }
            self.refreshPlaylists()
        }
    }

    /// Whether each channel starts playing when a clip lands in it.
    private var autoPlayByChannel: [String: Bool] = [:]

    /// Whether `channel` plays a clip as soon as it lands (its AUTO key, else the
    /// preference) — what a Clip Pad press follows.
    func autoPlays(_ channel: String) -> Bool {
        autoPlayByChannel[channel] ?? preferences.preferences.playOnLoad
    }

    /// Sets a channel's AUTO as its key would — for self-QA.
    func setAutoPlayForChecks(_ isOn: Bool, channel: String) {
        autoPlayByChannel[channel] = isOn
        shell.grid.panels.sourceBodies[channel]?.preview.setAutoPlayAppearance(on: isOn)
    }

    @objc private func sourceAutoPlayToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let letter = raw.split(separator: "|").last.map(String.init) else { return }
        let isOn = sender.state == .on
        autoPlayByChannel[letter] = isOn
        shell.grid.panels.sourceBodies[letter]?.preview.setAutoPlayAppearance(on: isOn)
        Log.info(.app, "source \(letter) auto-play \(isOn ? "on" : "off")")
    }

    /// Takes whatever is in a channel back out.
    ///
    /// The panel is told the channel is empty as well as the engine, because the
    /// caption and the Load/Eject button both read from that — an eject that cleared
    /// the picture but left the button saying Eject would strand the channel with no
    /// way to put anything back into it.
    ///
    /// EVERYTHING in the channel, not only the file. A channel showing a generator,
    /// an ISF generator, a camera or the Amiga reads from a different node than the
    /// file, so unloading the file alone cleared the caption and left that picture
    /// playing — Eject looked done and the source stayed on air. Ejecting routes the
    /// channel back to its (now empty) file node. What it was showing is not stopped:
    /// the Amiga is shared with other channels, and stopping a camera session blocks
    /// the main thread, which would stall a frame for an eject.
    private func ejectClip(fromChannel channel: String) {
        returnChannelToFile(channel)
        engine.unload(channel: channel)
        shell.grid.panels.sourceBodies[channel]?.setMediaName(nil)
        shell.grid.panels.sourceBodies[channel]?.setMarkedRange(nil)
        // A drive outliving the clip it was aimed at is a fader still moving on its
        // own with nothing behind it. Clearing the marks stops it and takes the STEP
        // key and its ✕ away with them.
        clearSweepsForCorruptor(channel: channel)
        Log.info(.clip, "ejected channel \(channel)")
    }

    /// Points a channel back at its file node, if it is showing anything else.
    ///
    /// Used by eject and by loading a clip: a file dropped onto a channel that was
    /// showing a generator was captioned with the file's name while the generator
    /// went on playing.
    private func returnChannelToFile(_ channel: String) {
        let showing = engine.channelSourceKinds[channel] ?? .file
        guard showing != .file else { return }
        setGenerator(nil, channel: channel)
        if showing == .emulator { shell.grid.panels.emuBrowser.refresh() }
    }

    /// Wires the libraries: double-click loads into the pair's next channel.
    /// Applies a picture fill to every preview in the window.

    func setPreviewFill(_ fill: PreviewFill) {
        let panels = shell.grid.panels
        // Seeds each SOURCE with the saved preference; from then on each one carries
        // its own, set from its own panel. The three composites follow the preference
        // and have no key, because everything reaching them is already 720x480.
        for (letter, body) in panels.sourceBodies {
            body.setFill(fill)
            engine.setFraming(fill, channel: letter)
        }
        // Never Centre on a composite. Its picture is always 720x480 and its monitor
        // is always smaller, so Centre there is a crop of the middle of what goes to
        // air — and a source's fill key writing Centre as the default for fresh
        // sources silently did that to all three monitors on the next launch.
        let compositeFill: PreviewFill = fill == .centre ? .fit : fill
        panels.subMixOneBody.preview.fillMode = compositeFill
        panels.subMixTwoBody.preview.fillMode = compositeFill
        panels.programBody.preview.fillMode = compositeFill
        Log.info(.render, "picture fill is now \(fill.displayName)")
    }

    /// True when nothing is being sent anywhere.
    var hasNoOutputs: Bool { router.hasNoOutputs && outputWindow == nil }

    /// The display Videoboy would choose for PROGRAM.
    func recommendedDisplay() -> DisplayInfo? { router.recommendedDisplay() }

    /// Sends PROGRAM to a display, as the first-run offer does.
    func routeProgram(to display: DisplayInfo) {
        router.route(.slot(Engine.outputSlot), to: .display(display.displayID))
    }

    /// Hangs the destination list off a preview's send glyph.
    private func presentRouting(for source: RoutingSource, from view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = RoutingPopover(
            source: source, router: router
        ) { [weak self, weak popover] destination in
            guard let self else { return }
            if let destination {
                // Picking a destination this source already goes to means "stop", the
                // way a checked item in any menu does.
                if self.router.destinations(showing: source).contains(destination) {
                    self.router.clear(destination)
                } else {
                    self.router.route(source, to: destination)
                }
            } else {
                for destination in self.router.destinations(showing: source) {
                    self.router.clear(destination)
                }
            }
            popover?.close()
        }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// Gives every preview a send glyph that knows what it is showing.
    private func wireRouting() {
        let panels = shell.grid.panels
        var sources: [(MetalPreviewView, RoutingSource)] = [
            // After DATA BURN, so a sub-mix sent straight to a display carries the
            // same burned-in data it carries into the mix.
            (panels.subMixOneBody.preview, .slot(Engine.dataBurnOneSlot)),
            (panels.subMixTwoBody.preview, .slot(Engine.dataBurnTwoSlot)),
            (panels.programBody.preview, .slot(Engine.outputSlot))
        ]
        for letter in Self.channels {
            guard let body = panels.sourceBodies[letter] else { continue }
            sources.append((body.preview, .slot(Engine.slot(forChannel: letter))))
        }

        for (preview, source) in sources {
            preview.onRoutingRequested = { [weak self] view in
                self?.presentRouting(for: source, from: view)
            }
        }

        // The four-up is offered from the PROGRAM preview, since that is where
        // someone looking for "show me everything" would reach first. Right-click,
        // because the plain click already means "send what this preview shows".
        panels.programBody.preview.routingButton?.menu = fourUpMenu()

        router.onFeedbackSendChanged = { [weak self] slot, bus in
            self?.engine.setFeedbackSend(from: slot, toBus: bus)
        }
        router.onRoutesChanged = { [weak self] in
            guard let self else { return }
            for (preview, source) in sources {
                preview.setRouted(!self.router.destinations(showing: source).isEmpty)
            }
        }
    }

    /// The right-click menu on PROGRAM's send glyph: the assembled views.
    private func fourUpMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Send four-up preview…", action: #selector(sendFourUp), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func sendFourUp() {
        guard let view = shell.grid.panels.programBody.preview.routingButton else { return }
        presentRouting(for: .fourUp, from: view)
    }

    private func wireLibraries() {
        let panels = shell.grid.panels
        // Each sub-mix library defaults to the pair it feeds. The browser starts on
        // A/B and can be pointed anywhere.
        panels.libraryOneBody.setDestinationPair(.ab)
        panels.libraryTwoBody.setDestinationPair(.cd)
        panels.assetBrowserBody.setDestinationPair(.ab)

        // The keys must show the SAVED state from the first frame, not their own
        // hardcoded default.
        for library in [panels.libraryOneBody, panels.libraryTwoBody, panels.assetBrowserBody] {
            library.setAutoPlay(preferences.preferences.playOnLoad)
        }

        shell.statusBar.onCancelImport = { [weak self] in self?.cancelImports() }
        shell.statusBar.onShowUnreadable = { [weak self] in self?.showUnreadable() }

        for library in [panels.libraryOneBody, panels.libraryTwoBody, panels.assetBrowserBody] {
            library.onFilesDropped = { [weak self] urls, bin in
                self?.addToLibrary(urls, library: library, intoBin: bin)
            }
            library.onAutoPlayChanged = { [weak self] isOn in
                guard let self else { return }
                self.preferences.preferences.playOnLoad = isOn
                // One preference, three libraries — they must not disagree about it.
                for other in [panels.libraryOneBody, panels.libraryTwoBody, panels.assetBrowserBody] {
                    other.setAutoPlay(isOn)
                }
                Log.info(.app, "auto-play on load \(isOn ? "on" : "off")")
            }
            library.onItemQueued = { [weak self] item, channel, playNext in
                guard let self, let url = item.url else { return }
                if playNext {
                    self.playlists[channel].insertNext(url: url)
                } else {
                    self.playlists[channel].append(url: url)
                }
                Log.info(.app, "queued \(url.lastPathComponent) on \(channel)"
                    + (playNext ? " (next)" : ""))
                self.refreshPlaylists()
            }
            library.onQueuedItemRemoved = { [weak self] channel, id in
                guard let self else { return }
                self.playlists[channel].remove(id: id)
                self.refreshPlaylists()
            }
            library.onItemOpened = { [weak self] item, channel, range in
                guard let self else { return }
                if let sourceID = item.configuredSourceID {
                    self.assignSource(sourceID, toChannel: channel)
                    return
                }
                if let moduleID = item.isfModuleID {
                    self.assignISFGenerator(moduleID, toChannel: channel)
                    return
                }
                if let kind = item.generatorKind {
                    self.setGenerator(kind, channel: channel)
                    self.shell.grid.panels.sourceBodies[channel]?.setMediaName(kind.displayName)
                    return
                }
                guard let url = item.url else {
                    self.presentNotice(
                        "\(item.name) is not a file",
                        "Generators and the other source kinds are loaded from their own "
                            + "panels, not from the library.")
                    return
                }
                self.loadClip(url, into: channel, range: range)
            }
        }

        refreshConfiguredSources()
        preferences.onChange = { [weak self] preferences in
            self?.refreshConfiguredSources()
            self?.applyDataBurnStyle(preferences.dataBurnStyle)
        }
    }

    /// Loads what a dragged generator or configured source refers to into a channel —
    /// the drag equivalent of double-clicking it in the asset browser.
    private func loadLibraryReference(_ reference: String, into letter: String) {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            Log.warn(.app, "a drop carried an unreadable library reference '\(reference)'")
            return
        }
        switch parts[0] {
        case "generator":
            guard let raw = Int(parts[1]), let kind = GeneratorKind(rawValue: raw) else { return }
            setGenerator(kind, channel: letter)
            shell.grid.panels.sourceBodies[letter]?.setMediaName(kind.displayName)
        case "isf":
            assignISFGenerator(parts[1], toChannel: letter)
        case "source":
            assignSource(parts[1], toChannel: letter)
        default:
            Log.warn(.app, "a drop carried an unknown library reference '\(reference)'")
        }
    }

    /// Rebuilds the Asset Browser's Sources tab from `Preferences.configuredSources`.
    ///
    /// Called once at launch and again on every change — adding, renaming or removing
    /// a source in Settings > Sources goes through `PreferenceStore.onChange`, which
    /// this is now the one subscriber to.
    private func refreshConfiguredSources() {
        shell.grid.panels.assetBrowserBody.configuredSourceItems =
            preferences.preferences.configuredSources.map { source in
                LibraryItem(
                    name: source.name, badge: source.kind.badge,
                    isAvailable: source.kind.isImplemented,
                    configuredSourceID: source.id)
            }
    }

    // MARK: - Recording

    /// Opens a take across every armed feed.
    private func startRecording(feeds: [String]) {
        let directory = preferences.preferences.saveLocation
            ?? RecordingSession.defaultDirectory()

        var slots: [String: String] = [:]
        for feed in feeds { slots[feed] = slot(forFeed: feed) }

        do {
            let session = try RecordingSession(
                feeds: slots,
                codec: shell.toolbar.selectedRecordCodec,
                directory: directory,
                metal: MetalContext.shared
            )
            recording = session
            // A feed that could not be opened is said once, here, rather than being
            // discovered afterwards as a missing file.
            if !session.failedFeeds.isEmpty {
                presentNotice(
                    "Recording \(session.activeFeeds.joined(separator: ", "))",
                    "\(session.failedFeeds.joined(separator: ", ")) could not be opened and "
                        + "is not being recorded. The others are running."
                )
            }
            Log.info(.app, "recording \(session.activeFeeds.joined(separator: ", ")) "
                + "to \(session.folder.path)")
        } catch {
            shell.toolbar.recordButton.isRecording = false
            presentNotice(
                "Could not start recording",
                "\(error.localizedDescription)\n\nFiles would have gone to \(directory.path)."
            )
        }
    }

    /// Closes the take and says where it went.
    private func stopRecording() {
        guard let session = recording else { return }
        recording = nil
        let folder = session.folder
        let frames = session.frameCount

        session.finish { [weak self] written in
            guard let self else { return }
            self.shell.grid.panels.settingsBarBody.setStreamStatus(self.router.streamSummary)
            guard !written.isEmpty else {
                self.presentNotice(
                    "Nothing was recorded",
                    "The take produced no frames. If the transport was stopped, the "
                        + "picture was not changing and nothing was written."
                )
                return
            }
            Log.info(.app, "take finished: \(written.count) files, \(frames) frames")
            self.presentRecordingFinished(folder: folder, files: written, frames: frames)
        }
    }

    /// Says where the take went, and offers to open it.
    private func presentRecordingFinished(folder: URL, files: [URL], frames: Int) {
        let seconds = Double(frames) / StandardDefinition.frameRate
        let alert = NSAlert()
        alert.messageText = "Recorded \(files.count) file\(files.count == 1 ? "" : "s")"
        alert.informativeText = String(
            format: "%@ · %.1f seconds\n\n%@",
            files.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", "),
            seconds,
            folder.path)
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    /// Adds dropped files to a library, skipping anything nothing here can open.
    ///
    /// Silently ignoring a file someone dropped is the worst option: it looks like
    /// the drop failed. Anything unplayable is named, once, with what this build can
    /// Every playable thing under a folder, with each folder becoming its own bin.
    ///
    /// Depth-first, and deliberately not flattened into one bin: the folders someone
    /// made are the grouping they already chose, and rebuilding it here would be
    /// inventing an organisation they did not ask for.
    ///
    /// Bounded, because a drop is a gesture and should not be able to start an
    /// unbounded walk of somebody's whole disk by accident — a home folder dropped by
    /// mistake would otherwise take minutes and fill the library with thousands of rows.
    static func itemsWalking(_ folder: URL) -> [LibraryItem] {
        // The rules live in Core now (ImportScan), where the import job uses them off
        // the main thread; this keeps the one synchronous caller (a self-QA) honest.
        ImportScan.walk(folder).map { candidate in
            var item = candidate.isSequence
                ? LibraryItem(name: candidate.url.lastPathComponent, badge: "SEQ",
                              isAvailable: true, url: candidate.url)
                : libraryItem(for: candidate.url)
            item.bin = candidate.bin
            return item
        }
    }


    /// actually read.
    /// - Parameter bin: where the drop or paste landed. Nil is the top level, where a
    ///   folder's shape on disk becomes bins; into a bin, everything is filed in THAT
    ///   bin, because bins are one level deep and the person chose where it goes.
    private func addToLibrary(_ urls: [URL], library: LibraryPanelBody, intoBin bin: String? = nil,
                              method: ImportMethod = .add, destination: URL? = nil,
                              root: URL? = nil, optimize: OptimizePreset? = nil) {
        // A BACKGROUND JOB, not a loop here: walking folders, reading posters and
        // measuring clips on the main thread froze the window on large drops and
        // looked like a crash (audit 09-26 R1–R3). Clips appear in the library as they
        // are found; the status bar reports when the import is big enough to worry about.
        let job = ImportJob(urls: urls, intoBin: bin, method: method, destination: destination, root: root)
        job.optimizePreset = method == .copy ? optimize : nil
        job.isLive = { [weak self] in self?.engine.transport.isRunning ?? false }
        job.onProgress = { [weak self] progress in self?.showImportProgress(progress) }
        job.onFinished = { [weak self, weak job] progress in
            guard let self, let job else { return }
            self.importFinished(job, progress: progress)
        }
        importJobs.append(job)
        LibraryPanelBody.importsRunning = importJobs.count
        job.start(into: shell.grid.panels.library)
    }

    /// Imports running or queued, oldest first. The status bar shows the latest news.
    private var importJobs: [ImportJob] = []
    /// What the last import could not read, for the status bar's "N unreadable".
    private var lastUnreadable: [String] = []
    /// Hides the import status a few seconds after the last import ends.
    private var importHideTimer: Timer?

    private func showImportProgress(_ progress: ImportProgress) {
        importHideTimer?.invalidate()
        lastUnreadable = progress.unreadable
        shell.statusBar.showImport(progress)
    }

    private func importFinished(_ job: ImportJob, progress: ImportProgress) {
        importJobs.removeAll { $0 === job }
        if let preset = job.optimizePreset, progress.stage == .finished {
            enqueueOptimize(job.resultingURLs, preset: preset)
        }
        LibraryPanelBody.importsRunning = importJobs.count
        showImportProgress(progress)
        if !progress.rejected.isEmpty {
            presentNotice(
                progress.rejected.count == 1
                    ? "Could not add \(progress.rejected[0])"
                    : "Could not add \(progress.rejected.count) files",
                "Videoboy reads .dv, .mov, .mp4, .m4v, .m2v, .mpg and .ts. "
                    + "These were left out:\n\n\(progress.rejected.joined(separator: "\n"))")
        }
        guard importJobs.isEmpty else { return }
        // In common modes, so it also fires inside the self-QA's nested run loop.
        let timer = Timer(timeInterval: Self.importStatusLinger, repeats: false) { [weak self] _ in
            self?.shell.statusBar.hideImport()
        }
        RunLoop.main.add(timer, forMode: .common)
        importHideTimer = timer
    }

    /// How long a finished import's summary stays in the status bar.
    static let importStatusLinger: TimeInterval = 3

    /// ✕ in the status bar: stops every import. What was added stays.
    private func cancelImports() {
        for job in importJobs { job.cancel() }
    }

    private func showUnreadable() {
        guard !lastUnreadable.isEmpty else { return }
        presentNotice(
            lastUnreadable.count == 1 ? "1 clip could not be read" : "\(lastUnreadable.count) clips could not be read",
            "They are in the library but will not play or show a picture:\n\n"
                + lastUnreadable.joined(separator: "\n"))
    }

    /// Imports files and folders chosen from File ▸ Import Clips…, as a drop on the
    /// library would.
    func importFiles(_ urls: [URL]) {
        addToLibrary(urls, library: shell.grid.panels.libraryOneBody)
    }

    /// Import mode's Import button: Add, Move or Copy, into a bin, as a background job.
    /// `root`: the folder the clips were picked from, whose tree is kept (ImportJob).
    func importFiles(_ urls: [URL], method: ImportMethod, destination: URL?, root: URL? = nil,
                     bin: String?, optimize: OptimizePreset? = nil) {
        addToLibrary(urls, library: shell.grid.panels.libraryOneBody, intoBin: bin,
                     method: method, destination: destination, root: root, optimize: optimize)
    }

    // MARK: - Copy + Optimize (0.4.10)

    /// One child process at a time, at background priority (see OptimizeQueue).
    private(set) lazy var optimizeQueue: OptimizeQueue = {
        let queue = OptimizeQueue { [weak self] in
            self?.preferences.preferences.optimizedMediaLocation
                ?? Preferences.defaultMoviesFolder.appendingPathComponent("Optimized Media")
        }
        queue.onStatus = { [weak self] text in
            guard let text else { return }
            self?.shell.statusBar.showNotice(text, detail: "Copy + Optimize, one clip at a time, "
                + "at background priority.", isWarning: false)
        }
        queue.onFinished = { [weak self] job, result, reason in
            guard let self else { return }
            if let result {
                self.shell.grid.panels.library.setOptimized(
                    path: result.path, canvas: ClipOptimizer.canvasTag, for: job.clipID)
            } else if reason != "stopped" {
                self.presentNotice("Could not optimize \(job.source.lastPathComponent) — it plays the original",
                                   reason ?? "unknown")
            }
        }
        return queue
    }()

    /// Converts clips now in the library (at these paths).
    func enqueueOptimize(_ urls: [URL], preset: OptimizePreset) {
        let ids = shell.grid.panels.library.idsByPath()
        let jobs = urls.compactMap { url -> OptimizeQueue.Job? in
            guard let id = ids[url.standardizedFileURL.path] else { return nil }
            return OptimizeQueue.Job(clipID: id, source: url, preset: preset)
        }
        optimizeQueue.enqueue(jobs)
    }

    /// Imports running now — for self-QA.
    var importJobsForChecks: Int { importJobs.count }

    /// What this build can open. Kept here rather than guessed at each call site.
    static let playableExtensions: Set<String> = ImportScan.playableExtensions

    /// A library entry for a file, badged by what it is.
    static func libraryItem(for url: URL) -> LibraryItem {
        let family = DataEffectFamily.forMediaFile(at: url)
        let badge: String
        switch family {
        case .mpeg: badge = "MPG"
        case .none: badge = url.pathExtension.uppercased()
        }
        return LibraryItem(
            name: url.lastPathComponent, badge: badge, isAvailable: true, url: url)
    }

    // MARK: - Shift-to-detect

    /// Which slot the crossfaders and shuttles belong to.
    ///
    /// The effect chains have their own tables because a code there means different
    /// slots on different buses. These are one-to-one, so they live here plainly
    /// rather than being bent to fit the same shape.
    private func wireDetect() {
        let panels = shell.grid.panels

        panels.faderABBody.fader.mappingSlot = GraphTopology.subMixOne
        panels.faderABBody.fader.mappingCode = .crossfadeAB
        panels.faderCDBody.fader.mappingSlot = GraphTopology.subMixTwo
        panels.faderCDBody.fader.mappingCode = .crossfadeCD
        panels.faderOneTwoBody.fader.mappingSlot = GraphTopology.primary
        panels.faderOneTwoBody.fader.mappingCode = .crossfadeOneTwo

        // Each shuttle scrubs its own source, so the slot is the channel itself.
        for (channel, body) in panels.sourceBodies {
            body.scrubFader?.mappingSlot = Self.slot(forChannel: channel)
            body.scrubFader?.mappingCode = .scrubPosition
        }

        // The effect chains answer per code, because a code names a different slot
        // on each bus.
        // (The FX panels' mapping resolver is set in `wireEffectChains`: a fader's
        // slot comes from its card's chain entry.)
        // Adding, removing or reordering an effect builds new fader views, which
        // start unmarked. Without this the pulse would quietly disappear from a
        // parameter that is still very much being driven.
        for panel in [panels.effectsOneBody, panels.effectsTwoBody] {
            panel.onChainRebuilt = { [weak self] in self?.refreshDrivenParameters() }
        }

        let session = DetectSession(root: shell)
        session.onDetectRequested = { [weak self] slot, code, accepting in
            self?.armDetect(slot: slot, code: code, accepting: accepting)
        }
        session.onArmedChanged = { [weak self] armed in
            self?.shell.toolbar.setDetectArmed(armed)
        }
        shell.toolbar.onDetectExplainRequested = { [weak self] in
            self?.presentNotice(
                "Hold Shift to map a control",
                "Every control that can be driven by MIDI lights up while Shift is held. Shift-click one, then move the knob or fader on your controller."
            )
        }
        detectSession = session
    }

    /// Faders with something driving them, cached so the beat pulse does not walk
    /// the view tree on every frame.
    private var drivenFaders: [VBFader] = []

    /// Re-reads which parameters have a driver and marks their faders.
    ///
    /// Asks the engine rather than keeping a parallel record of what has been mapped.
    /// A second copy of that list would be one more thing to forget to update, and
    /// the failure would be a fader claiming a driver it does not have — which is
    /// worse than no mark at all, because it would be believed.
    func refreshDrivenParameters() {
        drivenFaders.removeAll()
        markDriven(in: shell)
        Log.info(.param, "\(drivenFaders.count) parameters have a driver")
    }

    private func markDriven(in view: NSView) {
        if let fader = view as? VBFader,
           let slot = fader.mappingSlot, let code = fader.mappingCode {
            let driven = engine.registry.bindings.contains { $0.slot == slot && $0.code == code }
                || engine.audioReactivity.isDriven(slot: slot, code: code)
                || engine.lfos.isDriven(slot: slot, code: code)
            fader.isDriven = driven
            if driven { drivenFaders.append(fader) }
        }
        for subview in view.subviews { markDriven(in: subview) }
    }

    /// Which graph slot a channel letter is.
    private static func slot(forChannel channel: String) -> String {
        switch channel {
        case "A": GraphTopology.sourceA
        case "B": GraphTopology.sourceB
        case "C": GraphTopology.sourceC
        default:  GraphTopology.sourceD
        }
    }

    /// Arms MIDI learn for a parameter and says so, from wherever it was asked for.
    ///
    /// The status bar is the only report for controls with no badge of their own —
    /// a crossfader has nowhere to light up — so arming must be visible there or a
    /// mis-click looks like nothing happened.
    private func armDetect(
        slot: String, code: ParamCode, accepting: MIDIInput.DetectFilter = .anything
    ) {
        engine.midi.beginDetect(slot: slot, code: code, accepting: accepting)
        pendingLearn = (slot, code)
        installLearnKeys()
        // The status line says what to DO, not only what is happening. "Press a button
        // or pad" is the difference between a learn that works first time and one where
        // a stray knob takes the mapping and nobody knows why. And how to get OUT:
        // Esc backs out, ⌫ takes this control's mapping away.
        shell.statusBar.setMIDIDevice(
            "learning \(code.displayName) — \(accepting.prompt) · ⌫ unmaps · esc cancels")
        Log.info(.midi, "detect armed for \(slot)/\(code.rawValue)")
        engine.midi.onDetectCompleted = { [weak self] binding in
            // MIDI is drained on the main thread already; hop only if it ever is not.
            let finish = {
                guard let self else { return }
                self.pendingLearn = nil
                self.shell.statusBar.setMIDIDevice(self.engine.midi.connectedSourceNames.first)
                self.refreshDrivenParameters()
                // Light the effect's MIDI badge when the thing just mapped is that
                // effect's wet/dry. A mapping to one of its individual parameters has
                // nowhere to light up, and that is fine — it is no less real for it,
                // and the fader itself now carries the driven outline.
                self.lightEffectBadge(forSlot: slot, code: code, source: .midi)
                Log.info(.midi, "learned \(binding.source.description) for \(binding.slot)/\(binding.code.rawValue)")
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
    }

    /// Esc and ⌫ while a learn is armed. One monitor for the window's life; it only
    /// takes those two keys, and only while `pendingLearn` is set.
    private func installLearnKeys() {
        guard learnKeyMonitor == nil else { return }
        learnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleLearnKey(event) else { return event }
            return nil
        }
    }

    /// Esc cancels an armed learn, ⌫ unmaps its control. True when it took the key.
    /// Separate from the monitor so a check can deliver a real key event through it.
    @discardableResult
    func handleLearnKey(_ event: NSEvent) -> Bool {
        guard pendingLearn != nil else { return false }
        switch event.keyCode {
        case 53: cancelLearn()                 // Esc
        case 51, 117: unmapPendingLearn()      // Delete, Forward Delete
        default: return false
        }
        return true
    }

    /// Backs out of an armed learn: nothing is mapped, nothing is changed.
    func cancelLearn() {
        guard pendingLearn != nil else { return }
        engine.midi.cancelDetect()
        pendingLearn = nil
        shell.statusBar.setMIDIDevice(engine.midi.connectedSourceNames.first)
        Log.info(.midi, "learn cancelled")
    }

    /// Removes every MIDI mapping on the control a learn is armed for, and disarms.
    /// The one-control undo: Shift-click it, press ⌫.
    func unmapPendingLearn() {
        guard let (slot, code) = pendingLearn else { return }
        let removed = removeMappings(slot: slot, code: code)
        cancelLearn()
        presentNotice(
            removed > 0 ? "Unmapped \(code.displayName)" : "\(code.displayName) had no MIDI mapping",
            removed > 0 ? "Its MIDI mapping is removed. The control stays where it is." : "Nothing was changed.")
    }

    /// Settings removed mappings: re-read the driven outlines and the card badges.
    func mappingsChangedElsewhere() {
        refreshDrivenParameters()
        refreshCards(.one)
        refreshCards(.two)
    }

    /// Removes the MIDI mappings on one parameter; returns how many there were.
    @discardableResult
    func removeMappings(slot: String, code: ParamCode) -> Int {
        let matching = engine.registry.bindings.filter { $0.slot == slot && $0.code == code }
        for binding in matching { engine.registry.unbind(source: binding.source) }
        if !matching.isEmpty {
            lightEffectBadge(forSlot: slot, code: code, source: .midi, isActive: false)
            refreshDrivenParameters()
            Log.info(.midi, "unmapped \(slot)/\(code.rawValue) (\(matching.count) mapping(s))")
        }
        return matching.count
    }

    // MARK: - Wiring

    private func wireSources() {
        for letter in Self.channels {
            guard let body = shell.grid.panels.sourceBodies[letter] else { continue }
            body.onLoadRequested = { [weak self] in self?.presentOpenPanel(forChannel: letter) }
            body.onEjectRequested = { [weak self] in self?.ejectClip(fromChannel: letter) }
            // Only fires in ONE SHOT — the node decides that, not this closure.
            engine.sources[letter]?.onReachedEnd = { [weak self] in
                self?.playlistAdvance(channel: letter)
            }
            body.onPlayToggled = { [weak self] in self?.togglePlayback(channel: letter) }
            body.onFileSelected = { [weak self] in
                self?.setGenerator(nil, channel: letter)
                self?.captionChannel(letter)
            }
            body.onEmulatorSelected = { [weak self] in
                self?.assignEmulator(toChannel: letter)
            }
            body.onCameraSelected = { [weak self] in
                self?.assignCamera(toChannel: letter)
            }
            body.onSeekToStart = { [weak self] in
                self?.engine.sources[letter]?.seek(toNormalised: 0)
            }
            body.onSeekToEnd = { [weak self] in
                self?.engine.sources[letter]?.seek(toNormalised: 1)
            }
            body.onStepBack = { [weak self] in
                self?.engine.sources[letter]?.step(by: -1)
            }
            body.onStepForward = { [weak self] in
                self?.engine.sources[letter]?.step(by: 1)
            }
            body.onScrub = { [weak self] position in
                // Through the registry, not straight to the node: the shuttle and a
                // mapped jog wheel then move the same parameter rather than fighting
                // over the playhead from two directions.
                guard let self, let node = self.engine.sources[letter] else { return }
                self.engine.registry.setValue(
                    position, slot: node.identifier, code: .scrubPosition)
            }
            body.onTimingChanged = { [weak self] timing in
                self?.engine.sources[letter]?.timing = timing
            }
            // Per-source auto-play. The library's AUTO sets the default for a fresh
            // source; this decides it for THIS one, which is what you want when three
            // channels should start on load and one should not.
            body.preview.autoPlayCheckbox?.target = self
            body.preview.autoPlayCheckbox?.action = #selector(sourceAutoPlayToggled(_:))
            body.preview.autoPlayCheckbox?.identifier =
                NSUserInterfaceItemIdentifier("autoplay|\(letter)")
            body.preview.setAutoPlayAppearance(on: preferences.preferences.playOnLoad)
            autoPlayByChannel[letter] = preferences.preferences.playOnLoad

            body.onFillChanged = { [weak self] fill in
                // THE FEED, not only the monitor: the channel's picture is placed in the
                // canvas this way on the GPU, so what goes to the mix and to air changes.
                self?.engine.setFraming(fill, channel: letter)
                // The most recently chosen mode becomes what a fresh source starts
                // with, so setting it once does not mean setting it four times.
                self?.preferences.preferences.previewFill = fill
                Log.info(.render, "source \(letter) framing is now \(fill.displayName)")
            }
            body.onClipDropped = { [weak self] url, range in
                // The range travels with the drag now, so a dragged clip honours its
                // marks exactly as a double-clicked one does.
                self?.loadClip(url, into: letter, range: range)
            }
            body.onReferenceDropped = { [weak self] reference in
                self?.loadLibraryReference(reference, into: letter)
            }
            body.onLoopModeChanged = { [weak self] mode in
                self?.engine.sources[letter]?.loopMode = mode
                Log.info(.clip, "source \(letter) loop mode is now \(mode.displayName)")
            }
        }
    }

    private var playingChannels: Set<String> = []

    /// Points a channel at a generator, or back at its file.
    ///
    /// Also puts a transport-locked LFO on the generator's phase, because a static
    /// generator is not what any of them are for — a checkerboard that does not flip
    /// and a plasma that does not drift are wallpaper (SPEC 6A).
    private func setGenerator(_ kind: GeneratorKind?, channel letter: String) {
        guard let kind else {
            engine.setChannelSource(.file, channel: letter)
            engine.lfos.remove(
                slot: Engine.generatorSlot(forChannel: letter), code: .positionX)
            return
        }
        engine.generators[letter]?.generator = kind
        // A kind's parameters differ (Now Playing has its own), so the slot is
        // registered afresh and the Source Controls card rebuilt for them.
        if let node = engine.generators[letter] {
            engine.registry.register(slot: node.identifier, parameters: node.parameters)
        }
        engine.setChannelSource(.generator, channel: letter)
        refreshSourceCard(["A", "B"].contains(letter) ? .one : .two)
        if kind == .nowPlaying {
            // Asks macOS for Automation access the first time — only when someone
            // actually puts Now Playing on a channel, never at launch.
            NowPlayingWatcher.shared.start()
            return
        }

        // A slow ramp on phase by default: it drifts on the bar rather than
        // strobing, which is the sane starting point. The shape and rate are
        // ordinary parameters the performer can change or map.
        engine.lfos.assign(LFOBank.Assignment(
            lfo: LFO(shape: .rampUp, rate: .subdivision(.whole), depth: 1.0),
            slot: Engine.generatorSlot(forChannel: letter),
            code: .positionX,
            latencyInFrames: engine.generators[letter]?.latencyInFrames ?? 0
        ))
    }

    /// Wires the two ⇅ keys on the joins between the source windows.
    ///
    /// On the seam rather than the fader row on purpose: the fader row answers WHEN a
    /// source reaches air, and this answers WHICH CHANNEL A CLIP IS IN. Sitting between
    /// the two windows it operates on, it needs no legend to say which pair it means.
    private func wireSeamSwapKeys() {
        let panels = shell.grid.panels
        for (key, channels) in [(panels.swapAB, ("A", "B")), (panels.swapCD, ("C", "D"))] {
            key.onPressed = { [weak self] in
                guard let self else { return }
                guard self.engine.swapChannels(channels.0, channels.1) else { return }
                // Both panels have to be retold what they hold: the caption, the marked
                // range and the STEP key all describe the CLIP, and the clip has just
                // moved to the other panel.
                for letter in [channels.0, channels.1] {
                    self.refreshChannelAfterSwap(letter)
                }
            }
        }
    }

    /// Sends one parameter back to the default its NODE declares.
    ///
    /// The node is the authority, not the card model: `Parameter.defaultValue` is what
    /// the effect was written to sit at, while the card's `value` is a literal typed
    /// into `PanelSet` in thirty-two places. Resetting to the latter would look right
    /// today and drift the first time a node's default is tuned.
    ///
    /// Writes through `registry.setValue`, the same door a drag, a MIDI knob and an LFO
    /// all come through, so a reset cannot end up meaning something subtly different
    /// from setting the fader there by hand.
    private func resetParameter(card: String, code: String, bus: Bus) {
        guard let parameter = ParamCode(rawValue: code) else { return }
        guard let slot = slot(forEffect: card, bus: bus) else {
            Log.warn(.param, "no slot for \(card)/\(code); cannot reset it")
            return
        }
        guard let declared = engine.graph.nodes[slot]?.parameters
            .first(where: { $0.code == parameter }) else { return }

        engine.registry.setValue(declared.defaultValue, slot: slot, code: parameter)

        // Move the fader and its readout to match. The write above is the truth; this
        // is the panel catching up, and without it the control sits where it was
        // dragged while the engine is somewhere else — which reads as the key not
        // working.
        panel(bus).setDisplayedParameterValues(
            effectName: card, values: [code: declared.normalise(declared.defaultValue)])
        Log.info(.param, "reset \(slot)/\(code) to its default of \(declared.defaultValue)")
    }

    /// Brings a channel's panel back into line after its clip has been exchanged.
    ///
    /// Everything here describes the CLIP rather than the channel — which file it is,
    /// where its in and out points are, whether it steps to the beat — so all of it
    /// moved to the other panel when the clips did. Left alone, the two panels would go
    /// on captioning each other's media, which is worse than the swap not working:
    /// you would reach for the clip the label named and get the other one.
    private func refreshChannelAfterSwap(_ letter: String) {
        guard let node = engine.sources[letter],
              let body = shell.grid.panels.sourceBodies[letter] else { return }
        // The caption names WHAT THE CHANNEL SHOWS, which after a swap may not be a file
        // at all. Captioning the clip regardless would put a filename on a channel that
        // is showing the Amiga — a label describing a node the channel is not reading.
        captionChannel(letter)
        body.setMarkedRange(node.playbackRange)
        body.setTiming(node.timing)
        body.setScrubPosition(node.normalisedPosition)
    }

    /// Captions a channel's panel with whatever the channel is actually showing.
    ///
    /// The caption is also what turns Load into Eject, so every kind of source must
    /// set one. The Amiga and cameras used to set none: their channels read "Load",
    /// and the only way out was to load a file over them.
    private func captionChannel(_ letter: String) {
        guard let body = shell.grid.panels.sourceBodies[letter] else { return }
        switch engine.channelSourceKinds[letter] ?? .file {
        case .emulator:
            body.setMediaName("Amiga")
        case .generator:
            body.setMediaName(engine.generators[letter]?.generator.displayName ?? "Generator")
        case .capture(let id):
            let name = preferences.preferences.configuredSources.first { $0.id == id }?.name
            body.setMediaName(name ?? "Source")
        case .isfGenerator(let id):
            body.setMediaName(engine.catalog.generator(id)?.name ?? "ISF generator")
        case .file:
            let range = engine.sources[letter]?.playbackRange
            body.setMediaName(engine.sources[letter]?.mediaURL.map {
                range == nil ? $0.lastPathComponent : "\($0.lastPathComponent) [trimmed]"
            })
        }
    }

    /// Closes everything that owes the outside world an ending, at quit.
    ///
    /// `MPEGTSStreamer.close()` writes the trailer and flushes the encoder, and it was
    /// reachable only through `deinit` or `closeAll()` — neither of which process exit
    /// runs. So every stream this app ever sent ended TRUNCATED, and nothing said so.
    /// The display link is stopped for the same reason: it holds the engine, and a
    /// render tick arriving mid-teardown has nothing useful to do.
    ///
    /// Called from `applicationWillTerminate`. Safe to call twice: `closeAll` empties
    /// its dictionaries and `Engine.stop` clears the link it invalidates.
    func shutdown() {
        Log.info(.app, "shutting down: closing outputs and stopping the render clock")
        router.closeAll()
        sourceSessions.stopAll()
        engine.stop()
    }

    /// Connects the EMU tab to the graph.
    ///
    /// Called once, at startup: dragging the machine onto a source assigns it, and the
    /// machine coming up points whichever channels are already on it at the new host.
    private func wireEmulator() {
        let panels = shell.grid.panels
        panels.emuBrowser.onAssignedToChannel = { [weak self] letter in
            self?.assignEmulator(toChannel: letter)
        }
        // The node drives the SAME panel the EMU tab's faders drive, and its commands
        // go down the SAME bridge. That is what makes a MIDI knob, an LFO and a
        // beat-synced sweep reach the machine: they write to the registry, the node
        // reads it once a frame, and the translation layer turns the number into a
        // command exactly as a mouse would.
        engine.emulator?.panel = panels.emulator.panel
        engine.emulator?.onCommands = { [weak self] commands in
            self?.shell.grid.panels.emulator.send(commands)
        }

        panels.emulator.onMachineReady = { [weak self] host in
            // The node keeps whichever host it was given, so a machine started AFTER a
            // channel was pointed at it still reaches that channel. Without this,
            // assigning first and starting second gives a permanently empty source.
            self?.engine.emulator?.host = host
        }
    }

    /// Points a channel at the emulated machine.
    ///
    /// Starts it if it is not already running, because choosing "Amiga" from a source
    /// menu and getting an empty rectangle is indistinguishable from the feature being
    /// broken. If it cannot start, the EMU tab says why — so the menu choice still
    /// leads somewhere that explains itself.
    private func assignEmulator(toChannel letter: String) {
        let emulator = shell.grid.panels.emulator

        if !emulator.isRunning {
            guard emulator.isSetUp else {
                Log.warn(.titler, "channel \(letter) asked for the Amiga, but no machine "
                    + "has been set up — see the EMU tab in the asset browser")
                shell.grid.panels.emuBrowser.refresh()
                return
            }
            if emulator.start() { emulator.synchronise() }
        }

        engine.emulator?.host = emulator.host
        engine.setChannelSource(.emulator, channel: letter)
        captionChannel(letter)
        shell.grid.panels.emuBrowser.refresh()
    }

    /// Points a channel at a configured source (SPEC 6, SPEC 10) by id, starting its
    /// live session if it is not already running.
    ///
    /// The one path every route to a source goes through — a double-click on its tile
    /// in the Sources tab, or the per-channel "Camera" button below — so a channel and
    /// its preview always agree about what actually fed the graph edge.
    private func assignSource(_ id: String, toChannel letter: String) {
        guard let source = preferences.preferences.configuredSources.first(where: { $0.id == id })
        else { return }
        guard source.kind.isImplemented else {
            presentNotice(
                "\(source.name) is not connectable yet",
                source.kind.unimplementedReason ?? "This source kind is not built yet.")
            return
        }
        sourceSessions.start(source, engine: engine)
        engine.setChannelSource(.capture(id), channel: letter)
        captionChannel(letter)
    }

    /// The per-channel "Camera" button's fallback when there is no Sources-tab tile
    /// at hand. With exactly one configured, connectable source, that is obviously
    /// the one meant; with zero or several, guessing would be wrong more often than
    /// right, so this points at where the real choice lives instead.
    private func assignCamera(toChannel letter: String) {
        let candidates = preferences.preferences.configuredSources.filter { $0.kind.isImplemented }
        guard candidates.count == 1, let only = candidates.first else {
            presentNotice(
                candidates.isEmpty ? "No source configured" : "More than one source is configured",
                candidates.isEmpty
                    ? "Add a camera or a captured window in Settings > Sources."
                    : "Pick one from the Sources tab in the Asset Browser.")
            return
        }
        assignSource(only.id, toChannel: letter)
    }

    private func togglePlayback(channel letter: String) {
        if playingChannels.contains(letter) {
            playingChannels.remove(letter)
            engine.setPlaying(false, channel: letter)
        } else {
            playingChannels.insert(letter)
            engine.setPlaying(true, channel: letter)
        }
    }

    /// Opens a file for one channel. DV goes down the wedge's path; other formats are
    /// not wired to a decoder yet, and say so rather than failing silently.
    private func presentOpenPanel(forChannel letter: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = RepoPaths.samples
        panel.message = "Choose a video file for source \(letter)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadClip(url, into: letter)
    }

    /// Says what went wrong instead of silently doing nothing (SPEC 1.5).
    ///
    /// Never modal: this used to be `NSAlert.runModal()`, which froze the main thread
    /// — and with it the UI and every main-thread-driven part of the output — until
    /// someone clicked OK (BUGHUNT S6). It now goes to the status strip and the log.
    func presentNotice(_ title: String, _ detail: String) {
        Log.warn(.app, "notice: \(title) — \(detail)")
        shell.statusBar.showNotice(title, detail: detail)
    }

    /// Wires the blend mode of the three composites (SPEC 12).
    ///
    /// There is no separate opacity control any more: the crossfader IS the opacity.
    /// It travels base → blend → blend-layer, so hard left and hard right are the two
    /// sources untouched whatever the mode, and the blend is at full strength in the
    /// middle.
    private func wireBlendControls() {
        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne),
            (panels.subMixTwoBody, GraphTopology.subMixTwo),
            (panels.programBody, GraphTopology.primary)
        ]
        for composite in composites {
            composite.body.onScopeKeyPressed = { [weak self] key in
                self?.scopeKeyPressed(key, for: composite.slot, body: composite.body)
            }
            // Light the keys once at startup. Without this the placement and SEND keys
            // sit enabled over a scope that is not running until something is clicked,
            // which invites a click that does nothing.
            composite.body.setScopeSelection(
                scopeSelections[composite.slot] ?? defaultScopeSelection())
        }
    }

    /// Fades in flight, and cuts waiting for a beat, by bus slot.
    private var activeFades: [String: FadeAutomation] = [:]
    private var pendingCuts: [String: PendingCut] = [:]
    private var beatCutEnabled: [String: Bool] = [:]

    /// Advances any fade or pending cut. Called once per frame, before it renders.
    ///
    /// `now` is when the frame being rendered will be SEEN, so a fade's position is
    /// the one that belongs on screen at that moment, and a cut lands in the first
    /// frame shown at or after its `fireHostTime` — the beat's time LESS the graph's
    /// latency — which is what makes the picture change on the beat rather than a
    /// few frames after it (SPEC 21).
    private func updateFadesAndCuts(at now: CFTimeInterval) {

        for (slot, cut) in pendingCuts where cut.isDue(atHostTime: now) {
            pendingCuts.removeValue(forKey: slot)
            if let rate = cut.rate,
               let code = Self.faderCode(for: slot),
               let current = engine.registry.value(slot: slot, code: code) {
                activeFades[slot] = FadeAutomation(
                    from: current, to: cut.target, duration: rate.seconds, startedAt: now)
                takeStarted(on: slot, target: cut.target)
                Log.info(.clock, "fade started on beat \(String(format: "%.2f", cut.targetBeat)) for \(slot)")
            } else {
                applyFaderPosition(cut.target, to: slot)
                takeStarted(on: slot, target: cut.target)
                takeLanded(on: slot, target: cut.target)
                Log.info(.clock, "cut on beat \(String(format: "%.2f", cut.targetBeat)) taken for \(slot)")
            }
        }

        for (slot, fade) in activeFades {
            applyFaderPosition(fade.position(atHostTime: now), to: slot)
            if fade.isFinished(atHostTime: now) {
                activeFades.removeValue(forKey: slot)
                // A fade's outgoing side re-cues only once it is fully off air —
                // swapping its picture mid-dissolve would show on PROGRAM.
                takeLanded(on: slot, target: fade.to)
            }
        }
    }

    /// Writes a fader position into the registry and back into its panel.
    private func applyFaderPosition(_ position: Double, to slot: String) {
        guard let code = Self.faderCode(for: slot) else { return }
        engine.registry.setValue(position, slot: slot, code: code)
        Self.faderBody(for: slot, panels: shell.grid.panels)?.setPosition(position)
    }

    /// The crossfade param code for a bus slot.
    private static func faderCode(for slot: String) -> ParamCode? {
        switch slot {
        case GraphTopology.subMixOne: .crossfadeAB
        case GraphTopology.subMixTwo: .crossfadeCD
        case GraphTopology.primary: .crossfadeOneTwo
        default: nil
        }
    }

    /// The panel body for a bus slot.
    private static func faderBody(for slot: String, panels: PanelSet) -> FaderPanelBody? {
        switch slot {
        case GraphTopology.subMixOne: panels.faderABBody
        case GraphTopology.subMixTwo: panels.faderCDBody
        case GraphTopology.primary: panels.faderOneTwoBody
        default: nil
        }
    }

    /// Starts a fade, or schedules a cut, for one bus.
    /// - Parameter destination: where to land, or nil to travel to the far end.
    ///   A bus key names its own side, so it passes one; Fade does not, because
    ///   "fade" means "to the other one".
    /// Moves a bus, now or on the next beat.
    ///
    /// - Parameters:
    ///   - rate: nil for a cut, or how long to take over the fade. This is WHAT the
    ///     move is.
    ///   - waitsForBeat: whether to hold until the next subdivision boundary. This is
    ///     WHEN it happens. The two are independent — a fade can start on the beat
    ///     just as a cut can land on it — and one flag answering both is why pressing
    ///     Fade with beat-sync on produced a hard cut instead.
    ///   - destination: where to land, or nil to travel to the far end.
    private func beginMove(
        on slot: String, rate: FadeRate?, waitsForBeat: Bool, to destination: Double? = nil
    ) {
        guard let code = Self.faderCode(for: slot),
              let current = engine.registry.value(slot: slot, code: code) else { return }
        let target: Double = destination ?? (current < 0.5 ? 1.0 : 0.0)
        let now = CACurrentMediaTime()

        // A move supersedes whatever was already in flight on this bus, so pressing
        // Fade during a fade restarts it rather than the two fighting.
        activeFades.removeValue(forKey: slot)
        pendingCuts.removeValue(forKey: slot)

        guard waitsForBeat, engine.transport.isRunning else {
            // With the transport stopped there are no beats to wait for, so the move
            // happens now. Waiting forever would look like a dead button.
            if let rate {
                activeFades[slot] = FadeAutomation(
                    from: current, to: target, duration: rate.seconds, startedAt: now)
                takeStarted(on: slot, target: target)
            } else {
                applyFaderPosition(target, to: slot)
                takeStarted(on: slot, target: target)
                takeLanded(on: slot, target: target)
            }
            return
        }

        pendingCuts[slot] = PendingCut.scheduled(
            target: target,
            transport: engine.transport,
            subdivision: engine.beatSubdivision,
            hostTime: now,
            latencyInFrames: engine.graph.maximumLatencyInFrames,
            rate: rate
        )
    }

    // MARK: - Templates: save and open the whole show (audit L1)
    //
    // A template is the performance, not the instrument (Preferences are that): both
    // effect chains, every parameter value, every MIDI mapping, the clock, and what
    // each channel holds — clip and marks, playing, loop mode, or a generator /
    // configured source. `TemplateDocument` (Core) is the file; this is the bridge.

    /// The template file the show was last saved to or opened from.
    private(set) var currentTemplateURL: URL?
    /// Told when that changes (the window subtitle).
    var onTemplateURLChanged: ((URL?) -> Void)?

    /// The show as it is now.
    func captureTemplate(name: String) -> TemplateDocument {
        var channels: [String: TemplateChannel] = [:]
        for letter in ["A", "B", "C", "D"] {
            let source = engine.sources[letter]
            var channel = TemplateChannel(isPlaying: source?.isPlaying ?? false, loopMode: source?.loopMode,
                                          framing: engine.framing[letter])
            switch engine.channelSourceKinds[letter] ?? .file {
            case .file:
                channel.mediaPath = source?.mediaURL?.path
                channel.inPoint = source?.playbackRange?.lowerBound
                channel.outPoint = source?.playbackRange?.upperBound
            case .generator:
                if let kind = engine.generators[letter]?.generator { channel.reference = "generator:\(kind.rawValue)" }
            case .isfGenerator(let id):
                channel.reference = "isf:\(id)"
            case .capture(let id):
                channel.reference = "source:\(id)"
            case .emulator:
                Log.info(.template, "channel \(letter) shows the emulator; templates do not reopen it yet")
            }
            channels[letter] = channel
        }
        var document = TemplateDocument.capture(
            name: name, graph: engine.graph, registry: engine.registry,
            clock: TemplateClock(beatsPerMinute: engine.transport.beatsPerMinute,
                                 subdivision: engine.beatSubdivision.rawValue),
            chains: engine.chains, channels: channels)
        document.clipPads = clipPads?.bank
        return document
    }

    /// Writes the show to `url` and remembers it as the current template.
    func saveTemplate(to url: URL) throws {
        let name = url.deletingPathExtension().lastPathComponent
        try captureTemplate(name: name).write(to: url)
        currentTemplateURL = url
        onTemplateURLChanged?(url)
        Log.info(.template, "saved \(url.path)")
    }

    /// Replaces the show with a template: chains, values, mappings, clock, channels,
    /// and every control repainted to match.
    func openTemplate(_ document: TemplateDocument, from url: URL?) {
        engine.loadChains([.one: document.chain(for: .one), .two: document.chain(for: .two)])
        // The template's mappings REPLACE the current ones — opening a set is not a merge.
        for binding in engine.registry.bindings { engine.registry.unbind(source: binding.source) }
        let unknown = document.apply(to: engine.registry)
        engine.setTempo(document.clock.beatsPerMinute)
        shell.toolbar.setTempo(document.clock.beatsPerMinute)
        if let subdivision = Subdivision(rawValue: document.clock.subdivision) {
            engine.beatSubdivision = subdivision
        }

        for (letter, channel) in document.channels ?? [:] {
            let body = shell.grid.panels.sourceBodies[letter]
            if let framing = channel.framing {
                engine.setFraming(framing, channel: letter)
                body?.setFill(framing)
            }
            if let reference = channel.reference {
                loadLibraryReference(reference, into: letter)
                setChannelPlaying(letter, channel.isPlaying)
            } else if let path = channel.mediaPath {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    presentNotice("\(url.lastPathComponent) is missing — channel \(letter) left empty",
                                  "The template points at \(path), which is not there any more.")
                    ejectClip(fromChannel: letter)
                    continue
                }
                let range = channel.inPoint.flatMap { lower in channel.outPoint.map { lower...$0 } }
                loadClip(url, into: letter, range: range) { [weak self] loaded in
                    guard loaded, let self else { return }
                    if let mode = channel.loopMode {
                        self.engine.sources[letter]?.loopMode = mode
                        body?.setLoopMode(mode)
                    }
                    self.setChannelPlaying(letter, channel.isPlaying)
                }
            } else {
                ejectClip(fromChannel: letter)
            }
        }

        clipPads?.restore(document.clipPads)
        repaintFromRegistry()
        currentTemplateURL = url
        onTemplateURLChanged?(url)
        Log.info(.template, "opened \(document.name)" + (unknown > 0 ? " (\(unknown) mappings this build does not know)" : ""))
    }

    /// Sets every control on screen to what the registry holds — after a template load,
    /// when values changed without anyone touching the controls.
    func repaintFromRegistry() {
        refreshCards(.one)
        refreshCards(.two)
        func walk(_ view: NSView) {
            if let fader = view as? VBFader, let slot = fader.mappingSlot, let code = fader.mappingCode,
               let declared = engine.graph.nodes[slot]?.parameters.first(where: { $0.code == code }),
               let value = engine.registry.value(slot: slot, code: code) {
                fader.setDisplayedValue(declared.normalise(value))
            }
            view.subviews.forEach(walk)
        }
        walk(shell)
        let buses: [(body: FaderPanelBody, slot: String, code: ParamCode)] = [
            (shell.grid.panels.faderABBody, GraphTopology.subMixOne, .crossfadeAB),
            (shell.grid.panels.faderCDBody, GraphTopology.subMixTwo, .crossfadeCD),
            (shell.grid.panels.faderOneTwoBody, GraphTopology.primary, .crossfadeOneTwo)
        ]
        for bus in buses {
            if let position = engine.registry.value(slot: bus.slot, code: bus.code) { bus.body.setPosition(position) }
            if let blend = engine.registry.value(slot: bus.slot, code: .blendMode) {
                bus.body.setBlendModeForTemplate(BlendMode.from(normalised: blend))
            }
            if let transition = engine.registry.value(slot: bus.slot, code: .transition) {
                bus.body.transitionButton?.transition = Transition.from(normalised: transition)
            }
        }
        refreshDrivenParameters()
    }

    /// The show exactly as the app opened: taken once, at launch. "New" reopens it,
    /// rather than re-deriving a fresh state by hand (which effects start bypassed,
    /// which program stages start off, and so on are the engine's own decisions).
    private var launchTemplate: TemplateDocument?

    /// Remembers the launch state. Called once, after the window is built.
    func rememberLaunchState() {
        launchTemplate = captureTemplate(name: "untitled")
    }

    /// Back to a fresh show: the launch state, empty channels, no file.
    func newTemplate() {
        guard var fresh = launchTemplate else { return }
        fresh.channels = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "D"].map { ($0, TemplateChannel()) })
        openTemplate(fresh, from: nil)
        Log.info(.template, "new template")
    }

    // MARK: - A/B ROLL and ADV (docs/specs/ab-roll-adv.md)
    //
    // A TAKE is CUT, FADE, a bus key or their MIDI triggers moving a sub-mix from one
    // side to the other. A hand on the fader is not a take — rocking it would keep
    // loading clips. ROLL: the incoming source plays when the take STARTS (so a fade
    // dissolves in moving); the outgoing one pauses and re-cues when it has fully
    // LEFT air. ADV: the outgoing source loads its next clip at that same moment —
    // Up Next first, then the library fallback. The loading runs on the next run-loop
    // turn, never inside the render tick that took the cut.

    /// The two sub-mixes ROLL/ADV work on: their channels and preference key.
    private static let abRollBuses: [String: (left: String, right: String, key: String)] = [
        GraphTopology.subMixOne: ("A", "B", "one"),
        GraphTopology.subMixTwo: ("C", "D", "two")
    ]
    private var rollOn: [String: Bool] = [:]
    private var advanceOn: [String: Bool] = [:]
    private var pickers: [String: NextClipPicker] = [:]
    /// Which side each sub-mix last TOOK to (true = right), so a bus key pressed for
    /// the side already on air is not a take.
    private var takenSide: [String: Bool] = [:]
    /// Channels whose empty-queue fallback has been announced since Up Next last had
    /// something — said once per dry spell, not on every cut.
    private var announcedFallback: Set<String> = []

    /// ROLL on or off for a sub-mix (key click, MIDI, check).
    func setRoll(_ on: Bool, on slot: String) {
        guard Self.abRollBuses[slot] != nil else { return }
        rollOn[slot] = on
        Self.faderBody(for: slot, panels: shell.grid.panels)?.setRoll(on: on)
        Log.info(.app, "A/B ROLL \(on ? "on" : "off") for \(slot)")
    }

    /// ADV on or off for a sub-mix.
    func setAdvance(_ on: Bool, on slot: String) {
        guard Self.abRollBuses[slot] != nil else { return }
        advanceOn[slot] = on
        Self.faderBody(for: slot, panels: shell.grid.panels)?.setAdvance(on: on)
        if on {
            replanAdvance()
        } else if let bus = Self.abRollBuses[slot] {
            for channel in [bus.left, bus.right] {
                advancePlans[channel] = nil
                engine.discardPrepared(channel: channel)
            }
        }
        Log.info(.app, "ADV \(on ? "on" : "off") for \(slot)")
    }

    /// Plays or pauses a channel, keeping the play key's own record in step (the key
    /// and ROLL are linked controls: they must never disagree).
    func setChannelPlaying(_ channel: String, _ playing: Bool) {
        if playing { playingChannels.insert(channel) } else { playingChannels.remove(channel) }
        engine.setPlaying(playing, channel: channel)
    }

    /// A take began: with ROLL on, the incoming source rolls.
    private func takeStarted(on slot: String, target: Double) {
        guard let bus = Self.abRollBuses[slot] else { return }
        let side = target >= 0.5
        if let previous = takenSide[slot], previous == side { return }
        guard rollOn[slot] == true else { return }
        let take = ABRoll.take(channels: (bus.left, bus.right), target: target)
        setChannelPlaying(take.incoming, true)
    }

    /// A take landed (a cut is on air, a fade has finished): re-cue and/or advance
    /// the outgoing source — on the next run-loop turn, outside the render tick.
    private func takeLanded(on slot: String, target: Double) {
        guard let bus = Self.abRollBuses[slot] else { return }
        let side = target >= 0.5
        let isTake = takenSide[slot].map { $0 != side } ?? true
        takenSide[slot] = side
        guard isTake, rollOn[slot] == true || advanceOn[slot] == true else { return }
        let take = ABRoll.take(channels: (bus.left, bus.right), target: target)
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.settleOutgoing(take, slot: slot, busKey: bus.key)
        }
        CFRunLoopWakeUp(main)
    }

    /// What happens to the source that just left air.
    ///
    /// ZERO WAIT: ADV's next clip for this channel was chosen and OPENED in advance
    /// (`planAdvance`, after the previous take), so here it is only swapped in — no file
    /// is opened at the take. If the plan went stale (the queue or the fallback changed,
    /// or a different clip is on air) the pick is made now and opened off the main
    /// thread as before.
    private func settleOutgoing(_ take: ABRoll.Take, slot: String, busKey: String) {
        let rolls = rollOn[slot] == true
        let channel = take.outgoing
        guard advanceOn[slot] == true else {
            if rolls { recue(channel) }
            return
        }
        let pick: NextClipPicker.Pick?
        if let plan = advancePlans.removeValue(forKey: channel), isStillValid(plan, channel: channel, busKey: busKey, onAir: take.incoming) {
            playlists[channel] = plan.queueAfter
            pickers[busKey] = plan.pickerAfter
            pick = plan.pick
        } else {
            engine.discardPrepared(channel: channel)
            pick = nextClip(for: channel, onAir: take.incoming, busKey: busKey)
        }
        guard let pick else {
            if rolls { recue(channel) }
            return
        }
        let library = shell.grid.panels.library
        let item = library.items.first { $0.url?.standardizedFileURL == pick.url.standardizedFileURL }
        let range = item.flatMap { library.markedRange(for: $0.id) }
        let after: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            if rolls { self.recue(channel) }
            // The channel now on air is the next to leave it: choose and open ITS next
            // clip now, while it plays, so that take is instant too.
            self.planAdvance(for: take.incoming, onAir: channel, slot: slot, busKey: busKey)
        }
        let playing = playbackTarget(for: pick.url)
        var installed = false
        MainThreadCosts.measure("adv.install") {
            installed = engine.installPrepared(url: playing.url, intoChannel: channel)
        }
        if installed {
            advanceInstantCount += 1
            engine.sources[channel]?.playbackRange = range
            MainThreadCosts.measure("adv.clipLoaded") { clipLoaded(pick.url, into: channel, range: range, loaded: true) }
            MainThreadCosts.measure("adv.plan") { after(true) }
        } else {
            advanceWaitedCount += 1
            loadClip(pick.url, into: channel, range: range, then: after)
        }
        // The Up Next list redraws on the next turn — only this channel's — and without
        // re-planning: the take plans the next channel itself (`after`).
        schedulePlaylistViewRefresh(channel)
        if pick.fromQueue {
            announcedFallback.remove(channel)
        } else if preferences.preferences.announcesAdvanceFallback, !announcedFallback.contains(channel) {
            announcedFallback.insert(channel)
            let how = pick.fallback?.displayName.lowercased() ?? "library"
            shell.statusBar.showNotice(
                "Up Next \(channel) was empty — cued \(pick.url.lastPathComponent) (\(how))",
                detail: "ADV loads from the library when a queue runs out. "
                    + "Settings ▸ Defaults ▸ When Up Next runs out.",
                isWarning: false)
        }
        Log.info(.app, "ADV: \(channel) cued \(pick.url.lastPathComponent)"
            + (pick.fromQueue ? " from Up Next" : " (\(pick.fallback?.rawValue ?? "?"))"))
    }

    /// Paused on its head (the in point when trimmed), waiting to roll.
    private func recue(_ channel: String) {
        setChannelPlaying(channel, false)
        engine.sources[channel]?.seek(toNormalised: 0)
    }

    // MARK: ADV planning — the next clip, chosen and opened ahead of the take

    /// ADV's decision for one channel, made early. Commits at the take only if what it
    /// was based on has not changed.
    private struct AdvancePlan {
        let pick: NextClipPicker.Pick
        let pickerAfter: NextClipPicker
        let queueBefore: Playlist
        let queueAfter: Playlist
        let fallback: ABRollFallback
        let onAirURL: URL?
    }
    private var advancePlans: [String: AdvancePlan] = [:]
    /// Takes whose next clip was already open (instant) vs. opened at the take — self-QA.
    private(set) var advanceInstantCount = 0
    private(set) var advanceWaitedCount = 0

    private func isStillValid(_ plan: AdvancePlan, channel: String, busKey: String, onAir: String) -> Bool {
        plan.queueBefore == playlists[channel]
            && plan.fallback == (preferences.preferences.advanceFallback[busKey] ?? .inOrder)
            && plan.onAirURL == engine.sources[onAir]?.mediaURL
    }

    /// Chooses `channel`'s next ADV clip WITHOUT consuming anything (on copies of the
    /// queue and the picker), and starts opening it in the background.
    private func planAdvance(for channel: String, onAir: String, slot: String, busKey: String) {
        guard advanceOn[slot] == true else { return }
        // Keep a plan that still holds: re-picking would open a different clip for a
        // shuffle and waste the open already under way.
        if let existing = advancePlans[channel], isStillValid(existing, channel: channel, busKey: busKey, onAir: onAir) {
            return
        }
        var queue = playlists[channel]
        var picker = pickers[busKey] ?? NextClipPicker()
        guard let pick = pickNext(for: channel, onAir: onAir, busKey: busKey, queue: &queue, picker: &picker) else {
            advancePlans[channel] = nil
            engine.discardPrepared(channel: channel)
            return
        }
        advancePlans[channel] = AdvancePlan(
            pick: pick, pickerAfter: picker, queueBefore: playlists[channel], queueAfter: queue,
            fallback: preferences.preferences.advanceFallback[busKey] ?? .inOrder,
            onAirURL: engine.sources[onAir]?.mediaURL)
        let target = playbackTarget(for: pick.url)
        engine.prepareAhead(url: target.url, forChannel: channel, knownFrameCount: target.knownFrameCount)
    }

    /// Re-plans the channel on air on every bus with ADV on — when ADV is switched on
    /// and whenever a queue changes.
    private func replanAdvance() {
        for (slot, bus) in Self.abRollBuses where advanceOn[slot] == true {
            let position = engine.registry.value(slot: slot, code: slot == GraphTopology.subMixOne ? .crossfadeAB : .crossfadeCD) ?? 0
            let take = ABRoll.take(channels: (bus.left, bus.right), target: position)
            // On air now = the next to leave: plan for it.
            planAdvance(for: take.incoming, onAir: take.outgoing, slot: slot, busKey: bus.key)
        }
    }

    /// The file that would actually be PLAYED for a clip (its optimized file when
    /// there is one), and the catalog's frame count for it.
    func playbackTarget(for url: URL) -> (url: URL, knownFrameCount: Int?) {
        let library = shell.grid.panels.library
        let playing = preferences.preferences.usesOptimizedMedia
            ? library.playbackURL(for: url, canvas: ClipOptimizer.canvasTag) : (url: url, optimized: false)
        return (playing.url, playing.optimized ? nil : library.frameCount(forPath: url.path))
    }

    /// The next clip for a channel leaving air, or nil (commits the choice).
    private func nextClip(for channel: String, onAir: String, busKey: String) -> NextClipPicker.Pick? {
        var queue = playlists[channel]
        var picker = pickers[busKey] ?? NextClipPicker()
        let pick = pickNext(for: channel, onAir: onAir, busKey: busKey, queue: &queue, picker: &picker)
        pickers[busKey] = picker
        playlists[channel] = queue
        return pick
    }

    private func pickNext(for channel: String, onAir: String, busKey: String,
                          queue: inout Playlist, picker: inout NextClipPicker) -> NextClipPicker.Pick? {
        let panel = busKey == "one" ? shell.grid.panels.libraryOneBody : shell.grid.panels.libraryTwoBody
        let shown = panel.browser.fallbackOrder()
        let candidates = shown.compactMap { item in item.url.map { LibraryCandidate(url: $0, bin: item.bin) } }
        let outgoing = engine.sources[channel]?.mediaURL.map { url in
            LibraryCandidate(url: url, bin: shown.first { $0.url?.standardizedFileURL == url.standardizedFileURL }?.bin)
        }
        return picker.pick(
            queue: &queue, library: candidates,
            fallback: preferences.preferences.advanceFallback[busKey] ?? .inOrder,
            onAir: engine.sources[onAir]?.mediaURL, outgoing: outgoing,
            random: { Double.random(in: 0..<1) })
    }

    /// ADV takes served from a pre-opened clip vs. opened at the take — for self-QA.
    var advanceCountsForChecks: (instant: Int, waited: Int) { (advanceInstantCount, advanceWaitedCount) }

    /// ROLL / ADV state — for self-QA.
    func abRollStateForChecks(_ slot: String) -> (roll: Bool, advance: Bool) {
        (rollOn[slot] ?? false, advanceOn[slot] ?? false)
    }

    /// Queues a clip on a channel's Up Next — for self-QA.
    func queueForChecks(_ url: URL, channel: String) {
        playlists[channel].append(url: url)
        refreshPlaylists()
    }

    /// Loads a clip exactly as a drop would — for self-QA.
    func loadForChecks(_ url: URL, channel: String) { loadClip(url, into: channel) }

    private func wireFaders() {
        let panels = shell.grid.panels
        // Each fader writes straight into the registry, so a MIDI move and a mouse
        // drag land in exactly the same place.
        // A hand on a fader cancels whatever it was doing on its own.
        let buses: [(body: FaderPanelBody, slot: String)] = [
            (panels.faderABBody, GraphTopology.subMixOne),
            (panels.faderCDBody, GraphTopology.subMixTwo),
            (panels.faderOneTwoBody, GraphTopology.primary)
        ]
        for bus in buses {
            bus.body.setMappingSlot(bus.slot)
            bus.body.onSweepChanged = { [weak self] in self?.refreshArmedSweeps() }
            bus.body.onButtonAutomationChanged = { [weak self] in self?.refreshAutomatedButtons() }

            // Blend lives on the fader panel now, and writes to the same slot the
            // composite above it reads — the control moved, the wiring did not.
            bus.body.onBlendModeChanged = { [weak self] mode in
                self?.engine.registry.setValue(
                    mode.normalisedPosition, slot: bus.slot, code: .blendMode)
            }
            // The transition pattern, beside it: the same composite reads both, so
            // a wipe follows every fader move whether it came from a hand, FADE,
            // CUT, a sweep or MIDI.
            bus.body.onTransitionChanged = { [weak self] transition in
                self?.engine.registry.setValue(
                    transition.normalisedPosition, slot: bus.slot, code: .transition)
                // Leaving AVE-5 closes its block: it would be editing a wipe that
                // is no longer the one the fader follows.
                if transition != .ave5, self?.ave5Panel?.slot == bus.slot {
                    self?.closeAVE5Panel()
                }
            }
            bus.body.onAVE5PanelRequested = { [weak self] anchor in
                self?.toggleAVE5Panel(slot: bus.slot, anchor: anchor)
            }
            bus.body.onISFTransitionChanged = { [weak self] id in
                guard let self else { return }
                if !self.engine.setISFTransition(id, onMix: bus.slot) {
                    bus.body.transitionButton?.isfTransitionID = nil
                }
                if id != nil, self.ave5Panel?.slot == bus.slot { self.closeAVE5Panel() }
            }
            bus.body.onFade = { [weak self] rate in
                guard let self else { return }
                // Fade always fades. Beat only decides when it starts.
                self.beginMove(
                    on: bus.slot,
                    rate: rate,
                    waitsForBeat: self.beatCutEnabled[bus.slot] ?? false)
            }
            bus.body.onRollToggled = { [weak self] on in self?.setRoll(on, on: bus.slot) }
            bus.body.onAdvanceToggled = { [weak self] on in self?.setAdvance(on, on: bus.slot) }
            bus.body.onBeatCutToggled = { [weak self] on in
                self?.beatCutEnabled[bus.slot] = on
            }
            // CUT takes the OTHER source, wherever the fader currently is. Past the
            // halfway point it cuts to the near end, otherwise to the far one — so
            // the key always does the thing the picture is not already doing.
            bus.body.onCutRequested = { [weak self] in
                guard let self else { return }
                guard let code = Self.faderCode(for: bus.slot) else { return }
                let current = self.engine.registry.value(slot: bus.slot, code: code) ?? 0.5
                let target: Double = current >= 0.5 ? 0 : 1
                self.beginMove(
                    on: bus.slot, rate: nil,
                    waitsForBeat: self.beatCutEnabled[bus.slot] ?? false,
                    to: target)
                bus.body.setPosition(target)
                Log.info(.app, "cut on \(bus.slot) to \(target)")
            }

            bus.body.onCutTo = { [weak self] target in
                guard let self else { return }
                // The key has already moved the fader for an immediate cut; with beat
                // sync on it is put back and scheduled instead.
                guard self.beatCutEnabled[bus.slot] == true else {
                    // An immediate bus-key cut moved the fader itself; it is still a take.
                    self.takeStarted(on: bus.slot, target: target)
                    self.takeLanded(on: bus.slot, target: target)
                    return
                }
                self.beginMove(
                    on: bus.slot, rate: nil, waitsForBeat: true, to: target)
            }
        }

        panels.faderABBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.subMixOne)
            self?.pendingCuts.removeValue(forKey: GraphTopology.subMixOne)
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        }
        panels.faderCDBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.subMixTwo)
            self?.pendingCuts.removeValue(forKey: GraphTopology.subMixTwo)
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixTwo, code: .crossfadeCD)
        }
        panels.faderOneTwoBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.primary)
            self?.pendingCuts.removeValue(forKey: GraphTopology.primary)
            self?.engine.registry.setValue(position, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        }
    }

    /// Lights each preview by HOW MUCH OF IT IS ON AIR.
    ///
    /// ── WHY THIS IS MULTIPLIED DOWN THE CHAIN ───────────────────────────────────
    ///
    /// The obvious version lights A when the A/B fader is left. It is also wrong: if
    /// the programme fader is all the way over on C/D, then A is not on air at all, and
    /// a lit tally over a picture nobody can see is worse than no tally — it is a
    /// confident wrong answer to the one question this is for.
    ///
    /// So a source's level is its own fader's share MULTIPLIED by its sub-mix's share
    /// of the programme. Both faders have to favour you before you glow.
    ///
    /// ── AND WHY IT IS READ FROM THE REGISTRY, NOT FROM THE FADER ────────────────
    ///
    /// Because the fader is not the only thing that moves it. A cut, a timed fade, a
    /// MIDI CC, an LFO and a beat-synced sweep all write to the registry, and a tally
    /// driven from the view would sit still through every one of them. The registry is
    /// where the truth is, and three lookups a frame is nothing.
    private func updateTallies(from engine: Engine) {
        let panels = shell.grid.panels

        func value(_ slot: String, _ code: ParamCode, default fallback: Double) -> Double {
            engine.registry.value(slot: slot, code: code) ?? fallback
        }

        // 0 is the left-hand source of each pair, 1 the right-hand one.
        let ab = value(GraphTopology.subMixOne, .crossfadeAB, default: 0.5)
        let cd = value(GraphTopology.subMixTwo, .crossfadeCD, default: 0.5)
        let program = value(GraphTopology.primary, .crossfadeOneTwo, default: 0.5)

        let oneShare = 1 - program
        let twoShare = program

        // The sub-mixes: their share of the programme.
        panels.subMixOneBody.preview.onAirLevel = oneShare
        panels.subMixTwoBody.preview.onAirLevel = twoShare

        // The sources: their share of their own bus, times their bus's share of the
        // programme.
        panels.sourceBodies["A"]?.preview.onAirLevel = (1 - ab) * oneShare
        panels.sourceBodies["B"]?.preview.onAirLevel = ab * oneShare
        panels.sourceBodies["C"]?.preview.onAirLevel = (1 - cd) * twoShare
        panels.sourceBodies["D"]?.preview.onAirLevel = cd * twoShare

        // PROGRAM gets NO tally. It is the output: it is always on air, by definition,
        // so a lamp that is always lit tells you nothing. A tally answers "which of
        // these is going out", and on the one picture that always is, the answer is not
        // worth a red line around it — it is just a red line.
        panels.programBody.preview.onAirLevel = 0
    }

    // MARK: - Effect chains (ISF-PLAN M5 / M7)
    //
    // The FX panels show the engine's chains (EffectChain). Every card is built the
    // same way, from the module catalogue: its title, badge and faders come from the
    // module; its values from the registry, at whichever copy its selector targets.
    // There are no name tables: a card resolves to its chain entry, and the entry to
    // its slots. Adding, removing and reordering edit the chain and the engine
    // rewires the graph from it.

    /// The chain a panel shows.
    private func chainBus(_ bus: Bus) -> ChainBus { bus == .one ? .one : .two }

    /// The panel that shows a bus's chain.
    private func panel(_ bus: Bus) -> EffectChainPanelBody {
        bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
    }

    /// Card title → chain instance, per bus, as the cards were last built.
    private var cardInstances: [Bus: [String: String]] = [:]

    /// Whether the (flag-gated) corruptor card has been taken out, per bus.
    private var corruptorRemoved: Set<Bus> = []

    /// The Add menu's ID for the corruptor card, which is not a catalogue module.
    private static let corruptorModuleID = "fixed.corruptor"

    /// Polls ISF cards for "compiling…" / "⚠" while they settle.
    private var statusTimer: Timer?

    /// The chain entry behind a card.
    private func entry(forCard name: String, bus: Bus) -> ChainEntry? {
        guard let id = cardInstances[bus]?[name] else { return nil }
        return engine.chains[chainBus(bus)]?.entry(id)
    }

    /// The slot a card's controls currently edit — the copy its selector points at.
    private func slot(forEffect name: String, bus: Bus) -> String? {
        if name == PanelSet.corruptorCardName { return corruptorSlot(bus: bus) }
        if name == EffectChainPanelBody.sourceCardName {
            return engine.sourceSlot(forChannel: sourceChannel(bus: bus))
        }
        guard let entry = entry(forCard: name, bus: bus) else { return nil }
        return EffectChain.targetedSlot(of: entry, bus: chainBus(bus))
    }

    /// Every copy of a card: each channel's and the bus's.
    private func allSlots(forEffect name: String, bus: Bus) -> [String] {
        if name == PanelSet.corruptorCardName {
            return chainBus(bus).channels.map(Engine.slot(forChannel:))
        }
        if name == EffectChainPanelBody.sourceCardName {
            return [engine.sourceSlot(forChannel: sourceChannel(bus: bus))]
        }
        guard let entry = entry(forCard: name, bus: bus) else { return [] }
        return EffectChain.slots(instanceID: entry.instanceID, bus: chainBus(bus))
    }

    /// What a card's status line says about its node, if anything.
    private func status(of node: Node?) -> String? {
        switch node {
        case let isf as ISFNode:
            switch isf.state {
            case .compiling: return "compiling…"
            case .failed(let reason): return "⚠ \(reason)"
            case .ready:
                // A saved edit that does not work: the last good version keeps running.
                return isf.reloadProblem.map { "⚠ edit not applied (running the last good version): \($0)" }
            }
        case let missing as MissingModuleNode:
            return "⚠ \(missing.reason)"
        default:
            return nil
        }
    }

    /// Which badges should be lit for an effect's wet/dry — what the badges drive.
    private func activeModulationBadges(slot: String) -> Set<String> {
        var lit: Set<String> = []
        if engine.registry.bindings.contains(where: { $0.slot == slot && $0.code == .wetDry }) {
            lit.insert(ModulationSource.midi.badge)
        }
        if engine.audioReactivity.isDriven(slot: slot, code: .wetDry) { lit.insert(ModulationSource.audio.badge) }
        if engine.lfos.isDriven(slot: slot, code: .wetDry) { lit.insert(ModulationSource.lfo.badge) }
        return lit
    }

    /// Builds a panel's cards from its chain, top card first.
    private func makeCards(_ bus: Bus) -> [EffectCardModel] {
        let chainBus = chainBus(bus)
        guard let chain = engine.chains[chainBus] else { return [] }
        var cards: [EffectCardModel] = []
        var instances: [String: String] = [:]
        var used: Set<String> = []

        for entry in chain.displayOrder {
            let module = engine.catalog.module(entry.moduleID)
            // Titles are unique within a panel, because the card's controls are
            // identified by it: a second instance is "Bad TV 2".
            let base = module?.name ?? entry.moduleID
            var name = base
            var number = 2
            while used.contains(name) {
                name = "\(base) \(number)"
                number += 1
            }
            used.insert(name)
            instances[name] = entry.instanceID

            let slot = EffectChain.targetedSlot(of: entry, bus: chainBus)
            let node = engine.chainNode(slot)
            let declared = node?.parameters ?? []
            let available = module?.isAvailable ?? false
            let parameters = parameterModels(
                controls: module?.controls ?? [], declared: declared, slot: slot, available: available)
            var card = EffectCardModel(
                name: name, id: entry.instanceID,
                badge: module?.origin.badge ?? "missing",
                status: status(of: node),
                isEnabled: (engine.registry.value(slot: slot, code: .wetDry) ?? 0) > 0.5,
                isImplemented: available,
                parameters: parameters,
                channelOptions: chainBus.channels,
                initialChannelIndex: entry.target)
            // The badges say what is ACTUALLY driving this card, read from the engine.
            // Left empty, every rebuild (adding, removing or reordering any card)
            // turned every badge dark while its MIDI, LFO or audio kept driving.
            card.activeModulation = activeModulationBadges(slot: slot)
            cards.append(card)
        }

        // The corruptor is a fixed stage on the sources, not a chain module; its card
        // sits second from the top, where it always has.
        if !corruptorRemoved.contains(bus), let corruptor = PanelSet.corruptorCard(channels: chainBus.channels) {
            cards.insert(corruptor, at: min(1, cards.count))
        }
        cardInstances[bus] = instances
        return cards
    }

    // MARK: - Source Controls

    /// Which channel each bus's Source Controls card shows: 0 is A or C, 1 is B or D.
    private var sourceChannelIndex: [Bus: Int] = [:]

    private func sourceChannel(bus: Bus) -> String {
        let letters = chainBus(bus).channels
        return letters[min(max(sourceChannelIndex[bus] ?? 0, 0), letters.count - 1)]
    }

    /// Rebuilds only the pinned card, leaving the chain and its scroll alone.
    private func refreshSourceCard(_ bus: Bus) {
        let panel = panel(bus)
        let card = makeSourceCard(bus)
        sourceCardSignature[bus] = Self.signature(card)
        panel.sourceCard = card
        panel.refreshMappingAddresses()
    }

    /// What the Source Controls card SHOWS: its title and its controls. Two clips in a
    /// row give the same card, so an ADV swap need not rebuild it (a rebuild is an Auto
    /// Layout pass — ~7 ms of main thread next to a take).
    private var sourceCardSignature: [Bus: String] = [:]
    private static func signature(_ card: EffectCardModel) -> String {
        (card.subtitle ?? "") + "|" + (card.badge ?? "") + "|" + card.parameters.map(\.code).joined(separator: ",")
    }

    /// Rebuilds the card only if what it shows changed.
    private func refreshSourceCardIfChanged(_ bus: Bus) {
        let card = makeSourceCard(bus)
        guard Self.signature(card) != sourceCardSignature[bus] else { return }
        refreshSourceCard(bus)
    }

    /// The pinned card for the channel its selector points at: that source's own
    /// parameters, whatever kind of source it is.
    ///
    /// An ISF generator shows the controls its file declares, labelled and scaled
    /// exactly as an ISF effect card's are. A built-in pattern shows its node's four.
    /// A clip's speed and scrub already live on its source panel, and a camera or the
    /// emulator has none here — those say so rather than showing an empty box.
    private func makeSourceCard(_ bus: Bus) -> EffectCardModel {
        let letter = sourceChannel(bus: bus)
        let slot = engine.sourceSlot(forChannel: letter)
        let declared = engine.graph.nodes[slot]?.parameters ?? []
        var parameters: [EffectParameterModel] = []
        var subtitle: String
        var detail: String?
        var badge: String?

        switch engine.channelSourceKinds[letter] ?? .file {
        case .isfGenerator(let moduleID):
            let module = engine.catalog.generator(moduleID)
            subtitle = "\(letter) · \(module?.name ?? moduleID)"
            badge = "ISF"
            parameters = parameterModels(
                controls: module?.controls ?? [], declared: declared, slot: slot,
                available: module?.isAvailable ?? false)
        case .generator:
            subtitle = "\(letter) · \(engine.generators[letter]?.generator.displayName ?? "Generator")"
            badge = "generator"
            parameters = declared.map { parameter in
                EffectParameterModel(
                    // Phase is 12A (x) in the table, but on a pattern it is the phase
                    // the default LFO sweeps; call it what it does here.
                    name: parameter.code == .positionX ? "phase" : parameter.code.displayName,
                    code: parameter.code.rawValue,
                    value: parameter.normalise(
                        engine.registry.value(slot: slot, code: parameter.code) ?? parameter.defaultValue),
                    enabled: true)
            }
        // Every line below is short enough for the narrow FX column: it used to read
        // "A · bars.dv — speed and scrub are on its sour…". The file name and the
        // explanation go in the tooltip. The line does not wrap instead, because a
        // second line would push the whole chain down whenever a clip was loaded.
        case .file:
            let clip = engine.sources[letter]
            if (clip?.frameCount ?? 0) > 0 {
                subtitle = "\(letter) · clip — speed & scrub on \(letter)'s panel"
                detail = "\(letter) is playing \(clip?.mediaURL?.lastPathComponent ?? "a clip"). A clip's "
                    + "speed and scrub are on its source panel. Load a generator into \(letter) "
                    + "to control it here."
            } else {
                subtitle = "\(letter) · empty — load a generator"
                detail = "Nothing is loaded into \(letter). Load a generator into it — from the "
                    + "Generators tab — and its controls appear here."
            }
        case .capture(let id):
            let name = preferences.preferences.configuredSources.first(where: { $0.id == id })?.name
            subtitle = "\(letter) · live — no controls"
            detail = "\(letter) is showing \(name ?? "a live source"), which has no controls here."
        case .emulator:
            subtitle = "\(letter) · emulator — see EMU tab"
            detail = "\(letter) is showing the emulator. Its controls are on the asset browser's EMU tab."
        }

        return EffectCardModel(
            name: EffectChainPanelBody.sourceCardName, id: EffectChainPanelBody.sourceCardName,
            badge: badge, isEnabled: true, isImplemented: true,
            parameters: parameters,
            channelOptions: chainBus(bus).channels,
            initialChannelIndex: sourceChannelIndex[bus] ?? 0,
            subtitle: subtitle, subtitleDetail: detail ?? subtitle)
    }

    /// Fader models for a module's controls, read from the node's declared
    /// parameters and the registry. Shared by effect cards and Source Controls, so an
    /// ISF generator's controls look and scale exactly as an ISF effect's do.
    private func parameterModels(
        controls: [ModuleControl], declared: [Parameter], slot: String, available: Bool
    ) -> [EffectParameterModel] {
        controls.compactMap { control in
            guard let parameter = declared.first(where: { $0.code == control.code }) else { return nil }
            let value = engine.registry.value(slot: slot, code: control.code) ?? parameter.defaultValue
            // A trigger armed on the beat by another choice on the card: that
            // choice's values, converted to fader positions like every other.
            let beatArm = control.beatArm.flatMap { arm -> BeatArmModel? in
                guard let choice = declared.first(where: { $0.code == arm.code }) else { return nil }
                return BeatArmModel(
                    code: arm.code.rawValue,
                    armedValue: choice.normalise(arm.armedValue),
                    isArmed: { arm.isArmed(choice.denormalise($0)) })
            }
            return EffectParameterModel(
                name: control.label, code: control.code.rawValue,
                value: parameter.normalise(value), enabled: available,
                valueText: { control.valueText(parameter.denormalise($0)) },
                isTrigger: control.kind == .trigger,
                beatArm: beatArm,
                help: control.help)
        }
    }

    /// The Add menu: Built-in, then each ISF category, then what failed to load.
    private func addMenuGroups(_ bus: Bus) -> [EffectChainPanelBody.AddMenuGroup] {
        var byGroup: [String: [EffectChainPanelBody.AddMenuItem]] = [:]
        for module in engine.catalog.modules {
            byGroup[module.group, default: []].append(EffectChainPanelBody.AddMenuItem(
                moduleID: module.id, title: module.name, isEnabled: module.isAvailable,
                tooltip: module.problem ?? "\(module.origin.badge) · \(module.controls.count) controls"))
        }
        if corruptorRemoved.contains(bus), FeatureFlag.bitstreamCorruptor.isOn {
            byGroup["Built-in", default: []].insert(EffectChainPanelBody.AddMenuItem(
                moduleID: Self.corruptorModuleID, title: PanelSet.corruptorCardName,
                isEnabled: true, tooltip: nil), at: 0)
        }
        var groups: [EffectChainPanelBody.AddMenuGroup] = []
        if let builtIn = byGroup.removeValue(forKey: "Built-in") {
            groups.append(.init(title: "Built-in", items: builtIn))
        }
        for title in byGroup.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            groups.append(.init(title: title, items: byGroup[title] ?? []))
        }
        let failed = engine.catalog.unavailable
        if !failed.isEmpty {
            groups.append(.init(title: "Failed to load (\(failed.count))", items: failed.map {
                EffectChainPanelBody.AddMenuItem(moduleID: $0.id, title: $0.name, isEnabled: false, tooltip: $0.problem)
            }))
        }
        return groups
    }

    /// Rebuilds a panel's cards and Add menu from the chain and the catalogue.
    private func refreshCards(_ bus: Bus) {
        let panel = panel(bus)
        panel.setEffects(makeCards(bus))
        panel.sourceCard = makeSourceCard(bus)
        panel.addMenuGroups = addMenuGroups(bus)
        panel.refreshMappingAddresses()
        refreshArmedSweeps()
    }

    /// Both panels — after the catalogue changed (an ISF file added, fixed, removed).
    func refreshEffectPanels() {
        refreshCards(.one)
        refreshCards(.two)
        refreshISFGeneratorLists()
        refreshISFTransitionLists()
    }

    /// Puts the catalogue's ISF transitions in each crossfader's transition menu.
    private func refreshISFTransitionLists() {
        let entries = engine.catalog.transitions.map { (id: $0.id, name: $0.name) }
        let panels = shell.grid.panels
        for body in [panels.faderABBody, panels.faderCDBody, panels.faderOneTwoBody] {
            body.transitionButton?.isfTransitions = entries
        }
    }

    // MARK: - ISF generators (ISF-PLAN M9)

    /// Puts the catalogue's ISF generators in every library's Generators tab.
    ///
    /// - Parameter rerender: false when only a thumbnail finished, so the pictures
    ///   already made are kept.
    private func refreshISFGeneratorLists(rerender: Bool = true) {
        let generators = engine.catalog.generators
        // A hot reload may have changed a shader, so its picture is re-rendered.
        if rerender { GeneratorThumbnails.shared.forgetISF() }
        GeneratorThumbnails.shared.onISFUpdated = { [weak self] in
            self?.refreshISFGeneratorLists(rerender: false)
        }
        let items = generators.map { generator -> LibraryItem in
            var item = LibraryItem(
                name: generator.name, badge: "ISF", isAvailable: true, url: nil,
                id: "isf:\(generator.id)")
            item.isfModuleID = generator.id
            item.thumbnail = GeneratorThumbnails.shared.image(for: generator)
            return item
        }
        for library in [shell.grid.panels.libraryOneBody, shell.grid.panels.libraryTwoBody,
                        shell.grid.panels.assetBrowserBody] {
            library.isfGeneratorItems = items
        }
    }

    /// Points a channel at an ISF generator and says so on its panel.
    private func assignISFGenerator(_ moduleID: String, toChannel letter: String) {
        guard engine.setISFGenerator(moduleID, channel: letter) else {
            presentNotice("That generator is not available",
                          "It may have been removed from the ISF folder. The list refreshes when the folder changes.")
            return
        }
        // A generator is live, never a paused file: the file's LFO and transport no longer apply.
        engine.lfos.remove(slot: Engine.generatorSlot(forChannel: letter), code: .positionX)
        shell.grid.panels.sourceBodies[letter]?.setMediaName(engine.catalog.generator(moduleID)?.name ?? "ISF generator")
        Log.info(.isf, "channel \(letter) now runs ISF generator \(moduleID)")
    }

    /// Updates each card's status line from its node, without rebuilding anything.
    private func refreshCardStatuses() {
        for bus in [Bus.one, .two] {
            for (name, instanceID) in cardInstances[bus] ?? [:] {
                guard let entry = engine.chains[chainBus(bus)]?.entry(instanceID) else { continue }
                let node = engine.chainNode(EffectChain.targetedSlot(of: entry, bus: chainBus(bus)))
                panel(bus).setStatus(effectName: name, status: status(of: node))
            }
        }
    }

    private func wireEffectChains() {
        for bus in [Bus.one, .two] {
            let panel = panel(bus)
            panel.mappingSlotForParameter = { [weak self] card, _ in self?.slot(forEffect: card, bus: bus) }
            panel.onParameterChanged = { [weak self] card, code, value in
                self?.parameterChanged(card: card, code: code, value: value, bus: bus)
            }
            panel.onParameterReset = { [weak self] card, code in
                self?.resetParameter(card: card, code: code, bus: bus)
            }
            panel.onEffectModulationRequested = { [weak self] name, source, view in
                self?.presentModulationMenu(effect: name, source: source, from: view, bus: bus)
            }
            panel.onEffectRemoved = { [weak self] name in self?.removeEffect(name, bus: bus) }
            panel.onEffectAdded = { [weak self] moduleID in self?.addEffect(moduleID, bus: bus) }
            // Bypassing is expressed as wet/dry, so there is one mechanism rather than
            // a separate enable flag threaded through every node.
            panel.onEffectToggled = { [weak self] name, isOn in self?.setEffectEnabled(name, isOn, bus: bus) }
            panel.onSweepsChanged = { [weak self] in self?.refreshArmedSweeps() }
            panel.onCardChannelChanged = { [weak self] name, index in self?.cardChannelChanged(name, index, bus: bus) }
            // ORDER IS PROCESSING ORDER: a drag rewires the graph (it used to move
            // pictures of cards and nothing else).
            panel.onReordered = { [weak self] names in self?.chainReordered(names, bus: bus) }
            refreshCards(bus)
        }
        // A channel pointed at a different source shows that source's controls.
        // ADV's swap: refresh Source Controls if it is showing that channel, but do not
        // move it there (the channel just went OFF air).
        engine.onAdvanceInstalled = { [weak self] letter in
            guard let self else { return }
            let bus: Bus = ChainBus.one.channels.contains(letter) ? .one : .two
            if self.sourceChannel(bus: bus) == letter { self.refreshSourceCardIfChanged(bus) }
        }
        engine.onChannelSourceChanged = { [weak self] letter in
            guard let self else { return }
            let bus: Bus = ChainBus.one.channels.contains(letter) ? .one : .two
            // Follow the channel that just changed: loading a generator into B is
            // the moment someone wants B's controls in front of them.
            if let index = self.chainBus(bus).channels.firstIndex(of: letter) {
                self.sourceChannelIndex[bus] = index
            }
            self.refreshSourceCard(bus)
        }
        // Files added, edited or fixed in the ISF folders show up without a relaunch.
        engine.onModulesChanged = { [weak self] in self?.refreshEffectPanels() }
        engine.startWatchingModules()
        refreshISFGeneratorLists()
        refreshISFTransitionLists()

        // ISF modules compile off the render path; a card says "compiling…" until its
        // program arrives, and why, if it never does.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshCardStatuses()
        }
    }

    /// A fader on a card moved: write it to the copy the card targets.
    private func parameterChanged(card: String, code: String, value: Double, bus: Bus) {
        guard let parameter = ParamCode(rawValue: code), let slot = slot(forEffect: card, bus: bus) else {
            Log.warn(.param, "no slot for \(card)/\(code); ignoring the change")
            return
        }
        // The fader is 0...1; the registry scales it into the parameter's range.
        guard let declared = engine.graph.nodes[slot]?.parameters.first(where: { $0.code == parameter }) else { return }
        engine.registry.setValue(declared.denormalise(value), slot: slot, code: parameter)
    }

    /// The panel's cards were dragged into a new order.
    private func chainReordered(_ names: [String], bus: Bus) {
        let ids = names.compactMap { cardInstances[bus]?[$0] }
        engine.reorderChain(chainBus(bus), displayOrder: ids)
    }

    /// Every preview's record indicator, by the label it shows.
    private var recordIndicators: [String: MiniRecordIndicator] = [:]
    /// The take in progress, if any.
    private var recording: RecordingSession?

    // MARK: - Per-channel FX (chFX, SPEC 2)
    //
    // Every card reaches three copies — each channel's (upstream of the mix) and the
    // bus's (after it) — through its selector, which is the chain entry's `target`.
    // The DV corruptor is the exception: it lives on the source nodes themselves.

    /// Which channel each bus's corruptor card currently targets. 0 is this bus's
    /// first channel letter (A or C), 1 is its second (B or D).
    private var corruptorChannelIndex: [Bus: Int] = [:]

    private func corruptorChannel(bus: Bus) -> String {
        let letters = chainBus(bus).channels
        let index = corruptorChannelIndex[bus] ?? 0
        return letters[min(max(index, 0), letters.count - 1)]
    }

    private func corruptorSlot(bus: Bus) -> String {
        Engine.slot(forChannel: corruptorChannel(bus: bus))
    }

    /// The card's selector changed. Three things have to follow it, or the toggle
    /// would move the underlying data without changing what the screen shows: the
    /// Shift-detect address on every fader in the card, the enable switch (each
    /// copy's own bypass, not a single shared one), and the fader/readout values.
    private func cardChannelChanged(_ name: String, _ index: Int, bus: Bus) {
        if name == EffectChainPanelBody.sourceCardName {
            sourceChannelIndex[bus] = index
            refreshSourceCard(bus)
            return
        }
        if name == PanelSet.corruptorCardName {
            corruptorChannelIndex[bus] = index
        } else if let entry = entry(forCard: name, bus: bus) {
            engine.setTarget(index, of: entry.instanceID, on: chainBus(bus))
        }
        guard let slot = slot(forEffect: name, bus: bus) else { return }
        let panel = panel(bus)
        panel.refreshMappingAddresses()

        guard let node = engine.graph.nodes[slot] else { return }
        var displayed: [String: Double] = [:]
        for declared in node.parameters where declared.code != .wetDry {
            guard let value = engine.registry.value(slot: slot, code: declared.code) else { continue }
            displayed[declared.code.rawValue] = declared.normalise(value)
        }
        panel.setDisplayedParameterValues(effectName: name, values: displayed)

        let isEngaged = (engine.registry.value(slot: slot, code: .wetDry) ?? 1) > 0.5
        panel.setEnabled(effectName: name, isOn: isEngaged)

        Log.info(.param, "\(name) on \(bus == .one ? "ONE" : "TWO") now targets \(slot)")
    }

    /// Which graph slot each armable feed reads from.
    private func slot(forFeed label: String) -> String {
        switch label {
        case "1": Engine.dataBurnOneSlot
        case "2": Engine.dataBurnTwoSlot
        case "P": Engine.outputSlot
        default: Engine.slot(forChannel: label)
        }
    }

    /// What each composite's scopes are showing.
    private var scopeSelections: [String: ScopeSelection] = [:]
    /// Frame counter for pacing scope refreshes.
    private var scopeRefreshCounter = 0

    /// Handles one scope key, and updates everything that follows from it.
    private func scopeKeyPressed(
        _ key: PreviewPanelBody.ScopeKey, for slot: String, body: PreviewPanelBody
    ) {
        var selection = scopeSelections[slot] ?? defaultScopeSelection()

        switch key {
        case .kind(let kind):
            selection.toggle(kind)
        case .overlay:
            selection.isOverlaid.toggle()
        case .lowerThird:
            selection.isLowerThird.toggle()
        case .fileName:
            selection.showsFileName.toggle()
        case .timecode:
            selection.showsTimecode.toggle()
        case .burn:
            selection.isBurnedIn.toggle()
        }

        // Turning off the last thing shown turns DATA BURN off too. A burn key lit
        // over a picture with nothing burned into it reads as the burn being broken.
        if !selection.hasAnything {
            selection.isBurnedIn = false
        }

        scopeSelections[slot] = selection
        body.setScopeSelection(selection)

        if !selection.isShowing {
            body.preview.setScopeImage(nil)
        }
        updateBurn(for: slot, selection: selection, body: body)

        var shown = selection.orderedKinds.map(\.displayName)
        if selection.showsFileName { shown.append("name") }
        if selection.showsTimecode { shown.append("timecode") }
        Log.info(.app, "scopes on \(slot): "
            + (shown.isEmpty ? "off"
                : shown.joined(separator: "+") + " · \(selection.placement.displayName)"
                    + (selection.isBurnedIn ? " · BURNED IN" : "")))
    }

    /// A fresh selection, with the defaults that make the first click do the obvious
    /// thing: over the picture, filling the frame, not on air.
    private func defaultScopeSelection() -> ScopeSelection {
        var selection = ScopeSelection()
        selection.isOverlaid = true
        return selection
    }

    /// Puts a sub-mix's scope into its DATA BURN node, or takes it out.
    ///
    /// The text needs nothing here: the node pulls it each frame through the provider
    /// `wireDataBurn` gave it, which reads this same selection. PROGRAM has no burn
    /// node — its data arrives burned into the sub-mixes it is mixing.
    private func updateBurn(for slot: String, selection: ScopeSelection, body: PreviewPanelBody) {
        guard let burn = engine.dataBurns[slot] else { return }
        burn.placement = selection.placement
        burn.dimming = selection.isOverlaid ? 0 : 1
        if !selection.isBurnedIn || !selection.isShowing {
            burn.setOverlay(nil)
        }
        if selection.isBurnedIn {
            // The monitor now shows the burned picture; its own scope layer on top
            // would draw the instrument twice. `updateScopes` keeps it off.
            body.preview.setScopeImage(nil)
        }
    }

    // MARK: - NAME / TC

    /// NAME / TC lines last drawn on each composite's monitor, so an unchanged frame
    /// does not redraw them.
    private var monitorDataLines: [String: [String]] = [:]

    /// Gives each sub-mix's burn node its text, and the style from Preferences.
    private func wireDataBurn() {
        for (slot, burn) in engine.dataBurns {
            burn.textProvider = { [weak self] in
                guard let self,
                      let selection = self.scopeSelections[slot],
                      selection.isBurnedIn, selection.showsData else { return [] }
                return DataBurnText.lines(
                    self.dataEntries(forComposite: slot),
                    showsName: selection.showsFileName,
                    showsTimecode: selection.showsTimecode)
            }
        }
        applyDataBurnStyle(preferences.preferences.dataBurnStyle)
    }

    /// Restyles every burn and monitor block. Called when Preferences change.
    private func applyDataBurnStyle(_ style: DataBurnStyle) {
        for burn in engine.dataBurns.values { burn.textStyle = style }
        // Forget what the monitors drew, so the next frame redraws in the new style.
        monitorDataLines.removeAll()
    }

    /// Which corner each composite's text block uses. The sub-mixes match their burn
    /// nodes (see `Engine.buildGraph`); PROGRAM takes the middle, clear of both.
    private func dataAnchor(forComposite slot: String) -> DataBurnAnchor {
        switch slot {
        case GraphTopology.subMixOne: .topLeft
        case GraphTopology.subMixTwo: .topRight
        default: .topCentre
        }
    }

    /// The channels a composite's NAME / TC block describes.
    ///
    /// A sub-mix lists its two channels. PROGRAM lists S1 and S2, each describing the
    /// channel that sub-mix's fader favours. A line whose fader shuts it out entirely
    /// stays, blank after its label.
    private func dataEntries(forComposite slot: String) -> [DataBurnEntry] {
        let buses: [(label: String, mix: String, code: ParamCode, channels: [String])] = [
            ("S1", GraphTopology.subMixOne, .crossfadeAB, ["A", "B"]),
            ("S2", GraphTopology.subMixTwo, .crossfadeCD, ["C", "D"])
        ]
        func position(_ mix: String, _ code: ParamCode) -> Double {
            engine.registry.value(slot: mix, code: code) ?? 0.5
        }

        if let bus = buses.first(where: { $0.mix == slot }) {
            let fader = position(bus.mix, bus.code)
            return bus.channels.enumerated().map { index, letter in
                channelEntry(letter, label: letter,
                             isOnAir: DataBurnText.isOnAir(input: index, position: fader))
            }
        }

        let programFader = position(GraphTopology.primary, .crossfadeOneTwo)
        return buses.enumerated().map { index, bus in
            let favoured = position(bus.mix, bus.code) < 0.5 ? bus.channels[0] : bus.channels[1]
            return channelEntry(favoured, label: bus.label,
                                isOnAir: DataBurnText.isOnAir(input: index, position: programFader))
        }
    }

    /// One channel's name and playhead, whatever kind of source it is showing.
    private func channelEntry(_ letter: String, label: String, isOnAir: Bool) -> DataBurnEntry {
        switch engine.channelSourceKinds[letter] ?? .file {
        case .file:
            let clip = engine.sources[letter]
            let isLoaded = (clip?.frameCount ?? 0) > 0
            return DataBurnEntry(
                label: label,
                name: isLoaded ? clip?.mediaURL?.lastPathComponent : nil,
                frame: isLoaded ? clip.map { Int($0.playheadFrame) } : nil,
                isOnAir: isOnAir)
        case .generator:
            return DataBurnEntry(label: label, name: "Generator", frame: nil, isOnAir: isOnAir)
        case .emulator:
            return DataBurnEntry(label: label, name: "Emulator", frame: nil, isOnAir: isOnAir)
        case .isfGenerator(let module):
            return DataBurnEntry(label: label, name: module, frame: nil, isOnAir: isOnAir)
        case .capture(let id):
            let name = preferences.preferences.configuredSources
                .first(where: { $0.id == id })?.name ?? "Live source"
            return DataBurnEntry(label: label, name: name, frame: nil, isOnAir: isOnAir)
        }
    }

    /// Draws each composite's NAME / TC block onto its monitor. Every frame, because a
    /// timecode ticks every frame; the drawing itself happens only when a line changed.
    ///
    /// A sub-mix that is burning shows nothing here: its monitor already shows the
    /// burned picture, and a second copy on top would be the same text twice.
    private func updateMonitorData(from engine: Engine) {
        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne),
            (panels.subMixTwoBody, GraphTopology.subMixTwo),
            (panels.programBody, GraphTopology.primary)
        ]
        for composite in composites {
            let selection = scopeSelections[composite.slot] ?? ScopeSelection()
            let isBurned = selection.isBurnedIn && engine.dataBurns[composite.slot] != nil
            let lines = selection.showsData && !isBurned
                ? DataBurnText.lines(
                    dataEntries(forComposite: composite.slot),
                    showsName: selection.showsFileName,
                    showsTimecode: selection.showsTimecode)
                : []
            guard lines != monitorDataLines[composite.slot] else { continue }
            monitorDataLines[composite.slot] = lines

            // Drawn at the picture's own height, so the monitor's block is the same
            // size relative to the picture as the burned one.
            let picture = composite.body.preview.texture
            let frameWidth = picture?.width ?? 720
            let frameHeight = picture?.height ?? Int(DataBurnRenderer.referenceFrameHeight)
            guard let image = DataBurnRenderer.render(
                lines: lines, style: preferences.preferences.dataBurnStyle,
                frameHeight: frameHeight) else {
                composite.body.preview.setDataImage(nil, rect: (0, 0, 0, 0))
                continue
            }
            composite.body.preview.setDataImage(image, rect: DataBurnRenderer.rect(
                for: image, anchor: dataAnchor(forComposite: composite.slot),
                frameWidth: frameWidth, frameHeight: frameHeight))
        }
    }

    /// Connects each preview's arm indicator and records which feeds are armed.
    private func wireRecordIndicators() {
        let panels = shell.grid.panels
        var found: [String: MiniRecordIndicator] = [:]
        for letter in Self.channels {
            if let indicator = panels.sourceBodies[letter]?.preview.recordIndicator {
                found[letter] = indicator
            }
        }
        if let one = panels.subMixOneBody.preview.recordIndicator { found["1"] = one }
        if let two = panels.subMixTwoBody.preview.recordIndicator { found["2"] = two }
        if let program = panels.programBody.preview.recordIndicator { found["P"] = program }

        for (label, indicator) in found {
            indicator.target = self
            indicator.action = #selector(armChanged(_:))
            // PROGRAM is armed by default: recording the program feed is what anyone
            // means by "record" unless they say otherwise.
            indicator.isArmed = (label == "P")
        }
        recordIndicators = found
        Log.info(.app, "record indicators on \(found.keys.sorted().joined(separator: ", "))")
    }

    @objc private func armChanged(_ sender: MiniRecordIndicator) {
        let armed = recordIndicators.filter { $0.value.isArmed }.keys.sorted()
        Log.info(.app, "armed for recording: \(armed.isEmpty ? "nothing" : armed.joined(separator: ", "))")
    }

    /// Which sub-mix an FX panel drives.
    private enum Bus { case one, two }

    /// Takes a card out of its chain, with every copy. The Add menu is how it comes
    /// back — for a built-in, onto its old slot, with its mappings.
    private func removeEffect(_ name: String, bus: Bus) {
        if name == PanelSet.corruptorCardName {
            // A fixed stage: "remove" bypasses both channels' corruptors and hides the
            // card, so neither channel is left corrupting with no card to reach it.
            for slot in allSlots(forEffect: name, bus: bus) {
                engine.registry.setValue(0, slot: slot, code: .wetDry)
            }
            corruptorRemoved.insert(bus)
        } else if let entry = entry(forCard: name, bus: bus) {
            engine.removeModule(entry.instanceID, from: chainBus(bus))
        } else {
            Log.warn(.graph, "cannot remove \(name): not in the \(bus == .one ? "ONE" : "TWO") chain")
            return
        }
        refreshCards(bus)
        Log.info(.graph, "\(name) removed from bus \(bus == .one ? "ONE" : "TWO")")
    }

    /// Adds a module from the Add menu as the bottom card (applied first), bypassed.
    private func addEffect(_ moduleID: String, bus: Bus) {
        if moduleID == Self.corruptorModuleID {
            corruptorRemoved.remove(bus)
        } else if engine.addModule(moduleID, to: chainBus(bus)) == nil {
            return
        }
        refreshCards(bus)
    }

    /// Clears sweeps on faders that were aimed at a channel that has just emptied.
    ///
    /// Only the per-channel corruptor's faders follow a channel; the bus effects are
    /// downstream of the mix and keep working whatever is loaded, so their sweeps are
    /// deliberately left alone.
    private func clearSweepsForCorruptor(channel: String) {
        let bus: Bus = ["A", "B"].contains(channel) ? .one : .two
        guard corruptorChannel(bus: bus) == channel else { return }
        let panel = panel(bus)
        var cleared = 0
        for fader in VBFader.all(in: panel) where fader.sweep != nil {
            guard let code = fader.mappingCode,
                  [.corruptAmount, .corruptMode, .corruptRate, .corruptSeed].contains(code)
            else { continue }
            fader.clearSweep()
            cleared += 1
        }
        if cleared > 0 {
            Log.info(.param, "cleared \(cleared) sweep(s) aimed at ejected channel \(channel)")
            refreshArmedSweeps()
        }
    }

    /// Fires CUT and FADE when a learned MIDI button pushes their trigger to 1.
    ///
    /// Edge-triggered, not level-triggered. A controller holding a note down would
    /// otherwise cut on every frame for as long as it was held, which is a strobe
    /// rather than a cut. The value is put back to 0 once the action has fired, so
    /// the next press is a fresh edge.
    private func fireActionTriggers(from engine: Engine) {
        let buses: [(body: FaderPanelBody, slot: String)] = [
            (shell.grid.panels.faderABBody, GraphTopology.subMixOne),
            (shell.grid.panels.faderCDBody, GraphTopology.subMixTwo),
            (shell.grid.panels.faderOneTwoBody, GraphTopology.primary)
        ]
        for bus in buses {
            for code in [ParamCode.rollToggleTrigger, .advanceToggleTrigger] {
                guard let value = engine.registry.value(slot: bus.slot, code: code),
                      value > 0.5 else { continue }
                engine.registry.setValue(0, slot: bus.slot, code: code)
                if code == .rollToggleTrigger {
                    setRoll(!(rollOn[bus.slot] ?? false), on: bus.slot)
                } else {
                    setAdvance(!(advanceOn[bus.slot] ?? false), on: bus.slot)
                }
                Log.info(.midi, "\(code.displayName) toggled on \(bus.slot) from a mapping")
            }
            for code in [ParamCode.cutTrigger, .fadeTrigger, .cutToLeftTrigger, .cutToRightTrigger] {
                guard let value = engine.registry.value(slot: bus.slot, code: code),
                      value > 0.5 else { continue }
                engine.registry.setValue(0, slot: bus.slot, code: code)
                switch code {
                case .cutTrigger: bus.body.onCutRequested?()
                case .fadeTrigger: bus.body.onFade?(bus.body.currentRate)
                case .cutToLeftTrigger: bus.body.triggerLeftKey()
                case .cutToRightTrigger: bus.body.triggerRightKey()
                default: break
                }
                Log.info(.midi, "\(code.displayName) fired on \(bus.slot) from a mapping")
            }
            // The AVE-5 block's keys: a press each, on the edge, exactly like CUT.
            for key in AVE5Wipe.Key.allCases {
                guard let value = engine.registry.value(slot: bus.slot, code: key.triggerCode),
                      value > 0.5 else { continue }
                engine.registry.setValue(0, slot: bus.slot, code: key.triggerCode)
                pressAVE5(key, slot: bus.slot)
            }
        }
    }

    // MARK: - The AVE-5 wipe block
    //
    // The registry is the block's only state (62F–69F on each bus's slot): a click,
    // a learned MIDI key and a template all write there, and the popover, the key's
    // pictogram and the shader all read from there. So nothing can disagree about
    // which keys are lit.

    /// The fader buses, for the AVE-5 block's per-bus bookkeeping.
    private var ave5Buses: [(body: FaderPanelBody, slot: String)] {
        [
            (shell.grid.panels.faderABBody, GraphTopology.subMixOne),
            (shell.grid.panels.faderCDBody, GraphTopology.subMixTwo),
            (shell.grid.panels.faderOneTwoBody, GraphTopology.primary)
        ]
    }

    /// A bus's AVE-5 block, as the registry holds it.
    func ave5State(slot: String) -> AVE5Wipe {
        AVE5Wipe { engine.registry.value(slot: slot, code: $0) }
    }

    /// Presses one key of a bus's block — what a click on the popover and a learned
    /// MIDI key both come down to.
    func pressAVE5(_ key: AVE5Wipe.Key, slot: String) {
        var state = ave5State(slot: slot)
        state.press(key)
        writeAVE5(state, slot: slot)
        Log.info(.graph, "AVE-5 \(key.legend) on \(slot): \(state.shape.displayName)"
            + (state.multi == .off ? "" : " \(state.multi.label)")
            + (state.edge == .normal ? "" : ", \(state.edge.label.lowercased()) edge"))
    }

    /// Moves a bus's positioner.
    func positionAVE5(x: Double, y: Double, slot: String) {
        engine.registry.setValue(x, slot: slot, code: .ave5PositionX)
        engine.registry.setValue(y, slot: slot, code: .ave5PositionY)
        refreshAVE5()
    }

    private func writeAVE5(_ state: AVE5Wipe, slot: String) {
        for (code, value) in state.parameterValues {
            engine.registry.setValue(value, slot: slot, code: code)
        }
        refreshAVE5()
    }

    /// Brings the keys' pictograms and the open popover up to date with the
    /// registry. Every frame, because MIDI can change the block at any time; it
    /// costs eight dictionary reads per bus and redraws only on a change.
    private func refreshAVE5() {
        for bus in ave5Buses {
            let state = ave5State(slot: bus.slot)
            if ave5OnKeys[bus.slot] != state {
                ave5OnKeys[bus.slot] = state
                bus.body.setAVE5(state)
            }
        }
        if let panel = ave5Panel {
            panel.show(ave5State(slot: panel.slot))
        }
    }

    /// Opens the block for a bus, or closes it when it is already open for that bus.
    ///
    /// Application-defined rather than transient: a transient popover closes on the
    /// next click outside it, and the next click is the fader — the whole point is
    /// to set the keys and then play the wipe with the block still in view.
    func toggleAVE5Panel(slot: String, anchor: NSView) {
        if ave5Panel?.slot == slot {
            closeAVE5Panel()
            return
        }
        closeAVE5Panel()
        // A popover needs its anchor on screen. Headless checks build the shell
        // with no window; say so rather than raise.
        guard anchor.window != nil else {
            Log.info(.graph, "AVE-5 block not shown for \(slot): the key is not in a window")
            return
        }
        let panel = AVE5WipePanelController(slot: slot)
        panel.onPress = { [weak self] key in self?.pressAVE5(key, slot: slot) }
        panel.onPositionChanged = { [weak self] x, y in self?.positionAVE5(x: x, y: y, slot: slot) }
        panel.onChooseTransition = { [weak self] _ in
            guard let self else { return }
            let body = self.ave5Buses.first { $0.slot == slot }?.body
            body?.transitionButton?.showMenu()
        }
        panel.onClose = { [weak self] in self?.closeAVE5Panel() }
        panel.show(ave5State(slot: slot))

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = panel
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        ave5Popover = popover
        ave5Panel = panel
        // The popover is its own window: without this, Shift would light every key
        // in the main window and none of these.
        detectSession?.addRoot(panel.view)
        Log.info(.graph, "AVE-5 block open for \(slot)")
    }

    /// Closes the block if it is open.
    func closeAVE5Panel() {
        if let panel = ave5Panel {
            detectSession?.removeRoot(panel.view)
        }
        ave5Popover?.close()
        ave5Popover = nil
        ave5Panel = nil
    }

    /// Drives the sweeps once, for checks that step the graph by hand rather than
    /// through the display link.
    func driveSweepsForChecks() { driveSweeps(from: engine, at: CACurrentMediaTime()) }

    /// Polls the action-trigger codes once, for checks that need to prove a
    /// MIDI-mapped CUT/FADE/bus-key actually fires rather than just arming.
    func fireActionTriggersForChecks() { fireActionTriggers(from: engine) }

    /// Flips automated buttons once, for checks that step the beat by hand rather
    /// than through the display link.
    func flipAutomatedButtonsForChecks() { flipAutomatedButtons(from: engine) }

    /// Flips every automated button on its beat.
    ///
    /// A button has no range to travel, so automating one means flipping it — and
    /// flipping on a BOUNDARY rather than on a phase test, for the same reason the
    /// shuttle steps that way: at slow rates a phase test fires for several frames
    /// running, and at fast ones it can miss a boundary entirely between two frames.
    private func flipAutomatedButtons(from engine: Engine) {
        guard engine.transport.isRunning else { return }
        let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())

        for (key, lastInterval) in automatedButtons {
            guard let button = key.button, let rate = button.flipRate,
                  let beatsPerFlip = SweepRate.beatsPerCycle(rate), beatsPerFlip > 0
            else { continue }
            let interval = (beats / beatsPerFlip).rounded(.down)
            guard interval != lastInterval else { continue }
            automatedButtons[key] = interval
            button.isOn.toggle()
            _ = button.target?.perform(button.action, with: button)
        }
    }

    /// Automated buttons, with the flip interval each was last on.
    private var automatedButtons: [ObjectKey: Double] = [:]

    /// Rebuilds the automated-button list when one is armed or disarmed.
    private func refreshAutomatedButtons() {
        var found: [ObjectKey: Double] = [:]
        for panel in [shell.grid.panels.faderABBody,
                      shell.grid.panels.faderCDBody,
                      shell.grid.panels.faderOneTwoBody] {
            for key in VBOptionButton.all(in: panel) where key.isAutomated {
                found[ObjectKey(key)] = automatedButtons[ObjectKey(key)] ?? -1
            }
        }
        automatedButtons = found
        Log.info(.param, "\(found.count) button(s) flipping on the beat")
    }

    /// Drives every armed fader sweep, once a frame, at the time the frame will be seen.
    ///
    /// A fader with two marks stops being a control you hold and becomes one that
    /// plays itself between them on the clock. The fader owns the marks and the rate;
    /// this owns the clock and the registry, which is the only thing that has both.
    ///
    /// Writes through the SAME path a drag does — the panel's onParameterChanged
    /// closure — so a swept parameter and a dragged one cannot end up taking
    /// different routes into the engine.
    private func driveSweeps(from engine: Engine, at showAt: CFTimeInterval) {
        guard !armedSweeps.isEmpty else { return }
        guard engine.transport.isRunning else { return }
        let beats = engine.transport.beats(atHostTime: showAt)

        for entry in armedSweeps {
            guard let fader = entry.fader, let sweep = fader.sweep else { continue }
            let value = sweep.value(atBeats: beats)
            guard abs(value - fader.value) > 0.0005 else { continue }
            fader.value = value
            entry.write(value)
        }
    }

    /// Every fader currently carrying a sweep, with how to write its value.
    private var armedSweeps: [(fader: VBFader?, write: (Double) -> Void)] = []

    /// Rebuilds the list of armed faders. Called when any panel reports a change
    /// rather than rebuilt every frame, since arming is a gesture and frames are not.
    private func refreshArmedSweeps() {
        var found: [(fader: VBFader?, write: (Double) -> Void)] = []
        let panels: [(EffectChainPanelBody, Bus)] = [
            (shell.grid.panels.effectsOneBody, .one),
            (shell.grid.panels.effectsTwoBody, .two)
        ]
        for (panel, _) in panels {
            for fader in VBFader.all(in: panel) where fader.sweep != nil {
                guard let code = fader.mappingCode else { continue }
                // The panel's OWN closure — the identical route a drag takes — so a
                // swept parameter and a dragged one cannot diverge.
                guard let card = fader.ownerCard else { continue }
                found.append((fader, { [weak panel] value in
                    panel?.onParameterChanged?(card, code.rawValue, value)
                }))
            }
        }

        // THE CROSSFADERS TOO. They accepted the gesture and drew the bar, so a
        // sweep looked armed — but only the FX chains were ever scanned here, so
        // nothing drove them. A marked fader that never moves is worse than one that
        // refuses the gesture, because it says it worked.
        for body in [shell.grid.panels.faderABBody,
                     shell.grid.panels.faderCDBody,
                     shell.grid.panels.faderOneTwoBody] {
            let fader = body.fader
            guard fader.sweep != nil else { continue }
            found.append((fader, { [weak body] value in
                body?.onFaderMoved?(value)
            }))
        }
        armedSweeps = found
        Log.info(.param, "\(found.count) fader sweep(s) armed")
    }

    /// Moves the beat lights, every frame, but only repaints when the beat changes.
    ///
    /// These used to live in the once-a-second status block, whose comment said "once
    /// a second is plenty for a human reading them". True of a dropped-frame counter;
    /// completely wrong for the one readout in that block that is RHYTHMIC. At 120bpm
    /// a beat lands every half second, so sampling it once a second aliases — the
    /// indicator skips beats and settles on the wrong one, and at tempos that do not
    /// divide evenly into a second it drifts.
    ///
    /// Checked every frame so it lands on the right beat, repainted only when the
    /// number actually changes so it is not four layer writes per frame for nothing.
    private func updateBeatLights(from engine: Engine) {
        guard engine.transport.isRunning else {
            if lastDisplayedBeat != nil {
                lastDisplayedBeat = nil
                shell.toolbar.setBeat(-1)   // all four dim: nothing is counting
                shell.toolbar.setBeatPhase(0, isRunning: false)
            }
            return
        }

        // The PHASE, every frame, for the readout's pulse. Separate from the beat
        // number below, which only changes four times a bar: a pulse that updated on
        // the beat would be a blink, and what makes it read as a heartbeat is the
        // decay between beats.
        let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())
        shell.toolbar.setBeatPhase(beats - beats.rounded(.down), isRunning: true)

        let beat = engine.transport.position(atHostTime: CACurrentMediaTime()).beat
        guard beat != lastDisplayedBeat else { return }
        lastDisplayedBeat = beat
        shell.toolbar.setBeat(beat)
    }

    /// The beat the lights are currently showing, so they are only repainted on a
    /// change. Nil when the transport is stopped.
    private var lastDisplayedBeat: Int?

    /// Refreshes the scopes, well below frame rate.
    ///
    /// A scope reads a signal's shape, which does not change meaningfully between
    /// one frame and the next, and producing one needs a GPU readback plus a CPU
    /// pass. Refreshing every frame would put that in the render loop's way for no
    /// benefit a person could see. Roughly six times a second is plenty.
    private func updateScopes(from engine: Engine) {
        scopeRefreshCounter += 1
        guard let renderer = offscreenRenderer else { return }

        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String, texture: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne, engine.busOutputSlot(.one)),
            (panels.subMixTwoBody, GraphTopology.subMixTwo, engine.busOutputSlot(.two)),
            // Scopes must read what actually goes OUT, which is the end of the
            // programme chain — but BEFORE the scope overlay, or a sent scope would
            // measure itself and climb until the trace was solid white.
            (panels.programBody, GraphTopology.primary, Engine.outputSlot)
        ]

        // STAGGERED: each scope refreshes every `scopeRefreshInterval` frames as
        // before, but on its OWN frame — sub-mix one on 0, two on 1, programme on 2.
        // All three on the same frame put three GPU readbacks and three CPU composes
        // into one tick (data-burn p95 12.8 ms vs 6.6, audit 09-26 F6).
        for (offset, composite) in composites.enumerated() {
            guard scopeRefreshCounter % Self.scopeRefreshInterval == offset else { continue }
            let selection = scopeSelections[composite.slot] ?? ScopeSelection()
            guard selection.isShowing else { continue }

            guard let texture = engine.texture(for: composite.texture)
                ?? engine.texture(for: composite.slot),
                  let image = renderer.readback(texture) else { continue }

            // Drawn at the size it will be SHOWN at. Rendering full size and letting
            // the layer shrink it turns a one-pixel trace into a grey smear — which is
            // why the corner scope is small here rather than scaled down later.
            let size = selection.placement == .corner
                ? (width: 240, height: 144)
                : (width: 480, height: 360)
            guard let scope = ScopeRenderer.compose(
                selection, from: image, width: size.width, height: size.height) else { continue }

            // DATA BURN: the same image, handed to the sub-mix's burn node, so it
            // lands in the picture that goes into the mix. The monitor shows that
            // burned picture, so it does not draw its own copy on top.
            if selection.isBurnedIn, let burn = engine.dataBurns[composite.slot] {
                burn.placement = selection.placement
                burn.dimming = selection.isOverlaid ? 0 : 1
                burn.setOverlay(scope)
                composite.body.preview.setScopeImage(nil)
            } else {
                composite.body.preview.scopePlacement = selection.placement
                // Core's rule, the one the burn follows: a corner scope has its own
                // box and leaves the picture alone; over black hides the picture.
                // Only a scope drawn over the picture has its black keyed out — the
                // corner keeps its box, and over black there is nothing to see through.
                composite.body.preview.setScopeImage(
                    scope, pictureOpacity: Float(1 - selection.pictureDimming),
                    keysOutBlack: selection.isOverlaid && selection.placement != .corner)
            }
        }
    }

    /// Frames between scope refreshes. About six a second at 29.97.
    private static let scopeRefreshInterval = 5

    /// Used to read textures back for the scopes.
    private lazy var offscreenRenderer: OffscreenRenderer? = OffscreenRenderer()

    /// Advances every armed indicator's pulse from the musical clock.
    ///
    /// The pulse is derived from the transport rather than from a timer, so all the
    /// armed indicators are in step with each other and with the music by
    /// construction — a timer per indicator would drift apart within seconds.
    private func updateRecordPulse(from engine: Engine) {
        let isRecording = shell.toolbar.recordButton.isRecording
        let phase: Double
        if engine.transport.isRunning {
            let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())
            let cycle = beats / Theme.Record.pulseBeats
            phase = cycle - cycle.rounded(.down)
            // The window chrome breathes on the BEAT, not on the record pulse's two
            // beats — they are different rhythms and should not be conflated.
            let beatPhase = beats - beats.rounded(.down)
            shell.setBeatPhase(beatPhase)
        } else {
            // Stopped: hold the indicators at full brightness rather than freezing
            // them mid-fade, which reads as a rendering fault.
            phase = 0
            shell.clearBeatPulse()
        }
        for indicator in recordIndicators.values where indicator.isArmed {
            indicator.isRecording = isRecording
            indicator.pulsePhase = phase
        }
        // Driven parameters breathe on the BEAT, like the window chrome, rather than
        // on the record pulse's two beats.
        let drivenPhase = engine.transport.isRunning
            ? { let b = engine.transport.beats(atHostTime: CACurrentMediaTime())
                return b - b.rounded(.down) }()
            : 0
        for fader in drivenFaders {
            fader.pulsePhase = drivenPhase
            // And show WHERE the parameter actually is. A driven fader that glows but
            // never moves says something is happening and refuses to say what; the
            // value is right there in the registry, being written every frame by
            // whatever is driving it. The bar is the readout.
            guard let slot = fader.mappingSlot, let code = fader.mappingCode,
                  let declared = engine.graph.nodes[slot]?.parameters
                      .first(where: { $0.code == code }),
                  let value = engine.registry.value(slot: slot, code: code) else { continue }
            fader.setDisplayedValue(declared.normalise(value))
        }
    }

    /// Opens the MIDI / audio / LFO menu for a parameter and applies the choice.
    /// Lights an effect's badge when the mapping just made is that effect's wet/dry.
    private func lightEffectBadge(forSlot slot: String, code: ParamCode, source: ModulationSource,
                                  isActive: Bool = true) {
        guard code == .wetDry else { return }
        for bus in [Bus.one, .two] {
            let names = Array((cardInstances[bus] ?? [:]).keys) + [PanelSet.corruptorCardName]
            for name in names where self.slot(forEffect: name, bus: bus) == slot {
                panel(bus).setEffectModulationActive(effect: name, source: source, isActive: isActive)
            }
        }
    }

    /// Opens the modulation menu for a whole EFFECT.
    ///
    /// What gets driven is the effect's wet/dry — "how much of this effect", which is
    /// the thing you reach for at the effect level rather than at one parameter. It
    /// is also the toggle: wet/dry at zero is bypassed, so an LFO here gates the
    /// effect in and out in time, which is what makes it worth having on a badge.
    ///
    /// Individual parameters are mapped by holding Shift and clicking their fader.
    private func presentModulationMenu(
        effect name: String, source: ModulationSource, from view: NSView, bus: Bus
    ) {
        guard let slot = slot(forEffect: name, bus: bus) else {
            Log.warn(.param, "no slot registered for effect '\(name)'; cannot map it")
            return
        }
        let parameter = ParamCode.wetDry
        let badge = source.legacyLetter

        let panel = panel(bus)
        let isDriven: Bool
        switch source {
        case .midi: isDriven = engine.registry.bindings.contains { $0.slot == slot && $0.code == parameter }
        case .audio: isDriven = engine.audioReactivity.isDriven(slot: slot, code: parameter)
        case .lfo: isDriven = engine.lfos.isDriven(slot: slot, code: parameter)
        }

        ModulationMenus.present(badge: badge, isCurrentlyDriven: isDriven, from: view) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .learnMIDI:
                // The same act as Shift-clicking the fader, so it takes the same
                // path: the badge lights once something actually arrives, not on
                // arming, or it would claim a mapping that may never be made.
                self.armDetect(slot: slot, code: parameter)

            case .audio(let tap, let shape):
                self.engine.audioReactivity.assign(ReactivityAssignment(
                    tap: tap, shape: shape, slot: slot, code: parameter))
                panel.setEffectModulationActive(effect: name, source: .audio, isActive: true)
                if !self.engine.clockSource.isAudio {
                    // An audio mapping with no audio running would silently do
                    // nothing, which is the kind of thing found out mid-set. Worth
                    // saying once; not worth saying to someone who maps ten of them
                    // in a row and already knows.
                    ReminderAlert.show(
                        .audioMappingWithoutAudioClock,
                        store: self.preferences,
                        title: "Audio input is not running",
                        detail: "The mapping is saved, but nothing will move until you choose an audio source from CLOCK in the toolbar.",
                        buttons: ["OK"]
                    )
                }

            case .lfo(let shape, let rate):
                let latency = self.engine.graph.nodes[slot]?.latencyInFrames ?? 0
                self.engine.lfos.assign(LFOBank.Assignment(
                    lfo: LFO(shape: shape, rate: rate, depth: 1.0),
                    slot: slot, code: parameter, latencyInFrames: latency))
                panel.setEffectModulationActive(effect: name, source: .lfo, isActive: true)

            case .clear:
                switch badge {
                case "M":
                    self.removeMappings(slot: slot, code: parameter)
                case "S":
                    self.engine.audioReactivity.remove(slot: slot, code: parameter, restoringIn: self.engine.registry)
                default:
                    self.engine.lfos.remove(slot: slot, code: parameter, restoringIn: self.engine.registry)
                }
                // The switch shows the restored wet/dry, so it and the engine agree.
                if parameter == .wetDry {
                    panel.setEnabled(effectName: name, isOn: (self.engine.registry.value(slot: slot, code: .wetDry) ?? 0) > 0.5)
                }
                panel.setEffectModulationActive(effect: name, source: source, isActive: false)
            }
            // Whatever was chosen, the set of driven parameters may have changed.
            self.refreshDrivenParameters()
        }
    }

    /// Enables or bypasses a named effect on one of the buses.
    private func setEffectEnabled(_ name: String, _ isOn: Bool, bus: Bus) {
        guard let slot = slot(forEffect: name, bus: bus) else { return }
        engine.registry.setValue(isOn ? 1 : 0, slot: slot, code: .wetDry)
        Log.info(.app, "\(name) on \(bus == .one ? "ONE" : "TWO") \(isOn ? "enabled" : "bypassed")")
    }

    private func wireToolbar() {
        shell.toolbar.onPlayToggled = { [weak self] running in
            self?.engine.setTransportRunning(running)
        }
        shell.toolbar.onTap = { [weak self] in self?.tapTempo() }

        // The toolbar and the rails are two ways to do the same thing, so each keeps
        // the other in step rather than letting them disagree about what is shown.
        shell.toolbar.onPanelGroupToggled = { [weak self] panelGroup, collapsed in
            self?.shell.grid.setGroup(panelGroup, collapsed: collapsed)
        }
        shell.grid.onGroupCollapseChanged = { [weak self] panelGroup, collapsed in
            self?.shell.toolbar.setPanelGroupShown(panelGroup, !collapsed)
        }
        shell.toolbar.onRecordToggled = { [weak self] isRecording in
            guard let self else { return }
            let armed = self.recordIndicators.filter { $0.value.isArmed }.keys.sorted()
            if isRecording && armed.isEmpty {
                self.shell.toolbar.recordButton.isRecording = false
                self.presentNotice(
                    "Nothing is armed",
                    "Arm at least one feed first — click the dot in the top right of a preview."
                )
                return
            }
            if isRecording {
                self.startRecording(feeds: armed)
            } else {
                self.stopRecording()
            }
        }
        shell.toolbar.onSubdivisionChanged = { [weak self] name in
            guard let subdivision = Subdivision(rawValue: name) else { return }
            self?.engine.beatSubdivision = subdivision
        }
        shell.toolbar.onClockMenuRequested = { [weak self] anchor in
            guard let self else { return }
            ClockSourceMenu.present(current: self.engine.clockSource, from: anchor) { [weak self] choice in
                self?.chooseClockSource(choice)
            }
        }
    }

    /// Switches the clock source and says what happened.
    private func chooseClockSource(_ choice: ClockSource) {
        if engine.setClockSource(choice) {
            shell.toolbar.setClockSource(engine.clockSource.displayName)
            if choice.isAudio {
                shell.toolbar.setSyncStatus(SyncStatus(text: "listening", tone: .dim))
            } else {
                shell.toolbar.setSyncStatus(engine.transport.isRunning ? "running" : "stopped")
            }
            return
        }
        // The engine kept the old source; the field already shows it. Say why.
        guard case .audio(let source) = choice else { return }
        presentNotice(
            "Can't listen to \(source.longName)",
            engine.audioClockFailure ?? "Videoboy could not open that audio source."
        )
    }

    /// Shows what beat detection is doing, and acknowledges a new tempo.
    ///
    /// Four reports a second arrive here; the readout only redraws when its text or
    /// colour actually changes, and the flash only fires on a lock or relock — the
    /// moments the tempo genuinely jumped — never for drift.
    private func showBeatReport(_ report: BeatTrackerReport) {
        guard engine.clockSource.isAudio else { return }
        let status: SyncStatus
        switch report.state {
        case .silent:
            status = SyncStatus(text: "no signal", tone: .warning)
        case .listening:
            status = SyncStatus(text: "listening", tone: .dim)
        case .holding:
            status = SyncStatus(text: "holding", tone: .dim)
        case .locked:
            status = SyncStatus(
                text: String(format: "locked %.0f%%", report.confidence * 100), tone: .locked)
        }
        shell.toolbar.setSyncStatus(status)
        if let tempo = report.beatsPerMinute, report.state != .silent {
            shell.toolbar.setTempo(tempo)
        }
        switch report.event {
        case .locked(let tempo):
            Log.info(.clock, String(format: "beat detection locked at %.1f BPM", tempo))
            shell.toolbar.flashDetectedTempo()
            shell.flashTempoChange()
        case .relocked(let from, let to):
            Log.info(.clock, String(format: "beat detection moved %.1f -> %.1f BPM", from, to))
            shell.toolbar.flashDetectedTempo()
            shell.flashTempoChange()
        case .lost:
            Log.info(.clock, "beat detection lost the pulse; holding the tempo")
        case .silenced:
            Log.info(.clock, "beat detection hears silence")
        case nil:
            break
        }
    }

    /// Tap tempo: average the intervals between the last few taps.
    private var tapTimes: [CFTimeInterval] = []

    private func tapTempo() {
        let now = CACurrentMediaTime()
        // A gap longer than two seconds starts a new measurement rather than
        // averaging in a tap from some earlier moment.
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 4 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }

        let intervals = zip(tapTimes.dropFirst(), tapTimes).map(-)
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        let tempo = 60.0 / average
        // Ignore taps that imply an implausible tempo rather than lurching to it.
        guard tempo > 40, tempo < 300 else { return }
        engine.setTempo(tempo)
        shell.toolbar.setTempo(tempo)
    }

    /// The three variables behind each output emulation toggle.
    ///
    /// Three, and deliberately not more: the argument for these being two switches on
    /// the output bar rather than another effect panel is that they have sensible
    /// defaults and a short way in when they are not right.
    private func presentEmulationDetail(_ emulation: OutputEmulation, from view: NSView) {
        let controller: EmulationPopover
        switch emulation {
        case .ntsc:
            controller = EmulationPopover(
                heading: "NTSC signal",
                summary: "What the picture picks up on its way out as composite video. "
                    + "Applies to whatever is on air, after every bus effect.",
                slot: Engine.compositeProgramSlot,
                variables: [
                    .init(caption: "Dot crawl", code: .compositeCrawl),
                    .init(caption: "Chroma bleed", code: .chromaBleed),
                    .init(caption: "Luma bandwidth", code: .lumaBandwidth)
                ],
                registry: engine.registry
            )
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func wireSettingsBar() {
        shell.grid.panels.settingsBarBody.onOutputNTSCToggled = { [weak self] isOn in
            self?.engine.isOutputNTSCEnabled = isOn
        }
        shell.grid.panels.settingsBarBody.onEmulationDetailRequested = { [weak self] emulation, view in
            self?.presentEmulationDetail(emulation, from: view)
        }
        let settings = shell.grid.panels.settingsBarBody
        // Output is its own switch now. Test Pattern is a separate thing: what the
        // output SHOWS, not whether it is running — conflating them was part of what
        // made this bar confusing.
        settings.onOutputEnabledChanged = { [weak self] on in
            self?.setOutputWindowVisible(on)
        }
        settings.onTestPatternToggled = { [weak self] on in
            self?.setTestPatternVisible(on)
        }
        settings.onSafeZoneToggled = { [weak self] on in
            self?.setSafeZonesVisible(on)
        }
        settings.onOverscanToggled = { [weak self] on in
            // A single toggle picks a representative amount; the continuous control
            // is the 82A parameter, which a mapping or a template can drive.
            self?.engine.overscan = on ? 0.5 : 0.0
            self?.shell.grid.panels.programBody.preview.overscan = on ? 0.5 : 0.0
        }
        settings.onBlackFrameInsertionToggled = { [weak self] on in
            self?.engine.blackFrameInsertion = BlackFrameInsertion.from(normalised: on ? 0.5 : 0)
        }
    }

    /// Shows or hides the action-safe and title-safe overlays on every preview.
    private func setSafeZonesVisible(_ visible: Bool) {
        let panels = shell.grid.panels
        for letter in Self.channels {
            panels.sourceBodies[letter]?.preview.showsSafeZones = visible
        }
        panels.subMixOneBody.preview.showsSafeZones = visible
        panels.subMixTwoBody.preview.showsSafeZones = visible
        panels.programBody.preview.showsSafeZones = visible
    }

    // MARK: - Output

    /// Opens or closes the borderless output window on the configured display.
    func setOutputWindowVisible(_ visible: Bool) {
        guard visible else {
            outputWindow?.dismiss()
            outputWindow = nil
            shell.grid.panels.settingsBarBody.setOutput(destination: "off", mode: "—")
            return
        }
        let config = DeviceConfig.load()
        guard let display = DisplayRouter.preferredOutputDisplay(config: config) else {
            presentNotice("No display available", "Videoboy could not find a display to send output to.")
            shell.grid.panels.settingsBarBody.setOutputEnabled(false)
            return
        }
        let controller = OutputWindowController(display: display, requestedMode: config.requestedMode)
        controller.present()
        outputWindow = controller
        engine.setNegotiatedOutputMode(controller.negotiatedMode)
        shell.grid.panels.settingsBarBody.setOutput(
            destination: display.name, mode: controller.negotiatedMode)
    }

    /// Routes a test pattern to the program bus instead of the live mix.
    ///
    /// This is about what the output CARRIES; whether output is running at all is the
    /// Output switch beside it.
    private func setTestPatternVisible(_ visible: Bool) {
        engine.setProgramShowsTestPattern(visible)
    }

    // MARK: - Per-frame refresh

    /// Pushes this frame's textures and readouts into the views.
    private func refresh(from engine: Engine) {
        let panels = shell.grid.panels
        updateRecordPulse(from: engine)
        let showAt = engine.framePresentationTime

        for letter in Self.channels {
            // Ask the engine WHICH node this channel is playing from. Reading the
            // file slot unconditionally meant a channel showing a generator drew its
            // empty file node — the generator was reaching the bus and the mix, and
            // the one window that should have shown it stayed blank.
            let slot = engine.sourceSlot(forChannel: letter)
            panels.sourceBodies[letter]?.preview.texture = engine.texture(for: slot)
            // A clip that is not the canvas's shape carries bars; the monitor stripes them.
            let clip = engine.sources[letter]
            panels.sourceBodies[letter]?.preview.pictureRect =
                clip?.identifier == slot ? clip?.picturePlacement : nil
            panels.sourceBodies[letter]?.preview.present(at: showAt)
            // The scrub track follows playback, so it reads as a position indicator
            // as well as a control.
            if let source = engine.sources[letter], source.isPlaying {
                panels.sourceBodies[letter]?.setScrubPosition(source.normalisedPosition)
            }
        }

        // The END of each bus chain, not the bare crossfade.
        //
        // These previews were showing GraphTopology.subMixOne/Two, which is the
        // crossfade BEFORE the composite codec, echo, feedback and the data stage. So
        // turning on an effect changed PROGRAM while the sub-mix preview it belonged
        // to sat there unchanged — which reads as the effect landing in the wrong
        // window. A sub-mix preview must show that sub-mix as it will be mixed.
        //
        // After DATA BURN, so a burning sub-mix's monitor shows what it sends.
        panels.subMixOneBody.preview.texture = engine.texture(for: Engine.dataBurnOneSlot)
            ?? engine.texture(for: GraphTopology.subMixOne)
        panels.subMixOneBody.preview.present(at: showAt)
        panels.subMixTwoBody.preview.texture = engine.texture(for: Engine.dataBurnTwoSlot)
            ?? engine.texture(for: GraphTopology.subMixTwo)
        panels.subMixTwoBody.preview.present(at: showAt)

        // The end of the programme chain, falling back to the mix while the data
        // stage has produced nothing yet.
        let program = engine.texture(for: Engine.outputSlot)
            ?? engine.texture(for: GraphTopology.primary)
        panels.programBody.preview.texture = program
        panels.programBody.preview.present(at: showAt)
        outputWindow?.present(texture: program)

        // Everything else that has been routed somewhere. The four-up is assembled
        // here rather than in the graph because it is a view made FOR output, not a
        // stage anything downstream reads.
        if router.hasRoutes {
            router.present { [weak self] source in
                guard let self else { return nil }
                switch source {
                case .slot(let slot):
                    return self.engine.texture(for: slot)
                case .fourUp:
                    return self.router.tiled(Self.channels.map {
                        self.engine.texture(for: Engine.slot(forChannel: $0))
                    })
                case .scope(let slot):
                    return self.engine.texture(for: slot)
                }
            }
        }

        // Recording reads the same textures the previews do, so what is written is
        // what was on screen rather than a second render of the graph.
        if let recording {
            recording.write { [weak self] feed in
                guard let self else { return nil }
                let slot = self.slot(forFeed: feed)
                return self.engine.texture(for: slot)
                    ?? (feed == "P" ? self.engine.texture(for: GraphTopology.primary) : nil)
            }
        }

        updateTallies(from: engine)
        updateScopes(from: engine)
        // FILE / TC on the monitors. Written with DATA BURN and never called, so the
        // two keys lit and drew nothing unless the burn was on. Cheap when idle: it
        // redraws only when a line changes.
        updateMonitorData(from: engine)
        updateBeatLights(from: engine)
        fireActionTriggers(from: engine)
        flipAutomatedButtons(from: engine)
        clipPads?.tick()
        refreshAVE5()

        // The status and transport readouts are cheap, but not free; once a second is
        // plenty for a human reading them, and it keeps text redraw off the hot path.
        if engine.frameIndex % 30 == 0 {
            shell.statusBar.setNodeCount(engine.graph.nodeCount)
            shell.statusBar.setRate(
                droppedFrames: engine.droppedFrames,
                framesPerSecond: engine.measuredFramesPerSecond
            )
            shell.statusBar.setMIDIDevice(engine.midi.connectedSourceNames.first)
            shell.grid.panels.settingsBarBody.setStreamStatus(router.streamSummary)

            // The sync readout says what the clock is actually doing. With audio as
            // the clock, `showBeatReport` owns it — lock state and confidence, the
            // number the performer needs when deciding whether to trust detection
            // or tap the tempo in by hand.
            if !engine.clockSource.isAudio {
                shell.toolbar.setSyncStatus(engine.transport.isRunning ? "running" : "stopped")
            }
        }
    }
}

/// A weak, hashable handle to a view, for keying per-control state.
///
/// Keyed by identity rather than by name because two panels can hold buttons with the
/// same title, and a dictionary keyed on "CUT" would have them share one entry.
struct ObjectKey: Hashable {
    weak var button: VBOptionButton?
    private let identifier: ObjectIdentifier

    init(_ button: VBOptionButton) {
        self.button = button
        self.identifier = ObjectIdentifier(button)
    }

    static func == (lhs: ObjectKey, rhs: ObjectKey) -> Bool { lhs.identifier == rhs.identifier }
    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}
