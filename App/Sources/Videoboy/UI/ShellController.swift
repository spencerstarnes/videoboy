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

    private let shell: ShellView
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
        wireDetect()
        refreshDrivenParameters()
        engine.onTempoChanged = { [weak self] tempo in
            self?.shell.flashTempoChange()
            self?.shell.toolbar.setTempo(tempo)
        }
        engine.onBeatReport = { [weak self] report in self?.showBeatReport(report) }
        engine.onFrame = { [weak self] engine in self?.refresh(from: engine) }
    }

    /// Loads a clip into a channel and says what happened.
    ///
    /// The single path for every way a file arrives — double-clicked in a library,
    /// dragged onto a source, or chosen from the Load button — so a file that loads
    /// one way cannot silently fail another.
    private func loadClip(
        _ url: URL, into channel: String, range: ClosedRange<Double>? = nil
    ) {
        guard engine.load(url: url, intoChannel: channel) else {
            presentNotice(
                "Could not load \(url.lastPathComponent)",
                url.pathExtension.lowercased() == "dv"
                    ? "The file could not be read as DV. It may be truncated, or PAL — "
                        + "this build reads NTSC."
                    : "The file could not be opened. It may use a codec macOS cannot "
                        + "read, or have no video track."
            )
            return
        }
        engine.sources[channel]?.playbackRange = range
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
        Log.info(.dv, "loaded \(url.lastPathComponent) into channel \(channel)")
    }

    /// One up-next queue per source (A, B, C, D).
    ///
    /// Only consulted when a source is in ONE SHOT — see `Playlist`. Loop and
    /// ping-pong have their own answer for what happens at the end of a clip.
    private var playlists = PlaylistSet()

    /// Pushes the queues back into whichever library shows them.
    private func refreshPlaylists() {
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
            Log.info(.dv, "\(channel) taking \(next.displayName) from its playlist")
            self.loadClip(next.url, into: channel)
            // Up next means up NEXT — it plays, rather than landing paused and
            // waiting for someone to notice the clip changed.
            self.engine.setPlaying(true, channel: channel)
            self.refreshPlaylists()
        }
    }

    /// Whether each channel starts playing when a clip lands in it.
    private var autoPlayByChannel: [String: Bool] = [:]

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
    private func ejectClip(fromChannel channel: String) {
        engine.unload(channel: channel)
        shell.grid.panels.sourceBodies[channel]?.setMediaName(nil)
        shell.grid.panels.sourceBodies[channel]?.setMarkedRange(nil)
        // A drive outliving the clip it was aimed at is a fader still moving on its
        // own with nothing behind it. Clearing the marks stops it and takes the STEP
        // key and its ✕ away with them.
        clearSweepsForCorruptor(channel: channel)
        Log.info(.dv, "ejected channel \(channel)")
    }

    /// Wires the libraries: double-click loads into the pair's next channel.
    /// Applies a picture fill to every preview in the window.

    func setPreviewFill(_ fill: PreviewFill) {
        let panels = shell.grid.panels
        // Seeds each SOURCE with the saved preference; from then on each one carries
        // its own, set from its own panel. The three composites follow the preference
        // and have no key, because everything reaching them is already 720x480.
        for body in panels.sourceBodies.values { body.setFill(fill) }
        panels.subMixOneBody.preview.fillMode = fill
        panels.subMixTwoBody.preview.fillMode = fill
        panels.programBody.preview.fillMode = fill
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
            (panels.subMixOneBody.preview, .slot(Engine.busCodecOneSlot)),
            (panels.subMixTwoBody.preview, .slot(Engine.busCodecTwoSlot)),
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

        for library in [panels.libraryOneBody, panels.libraryTwoBody, panels.assetBrowserBody] {
            library.onFilesDropped = { [weak self] urls in
                self?.addToLibrary(urls, library: library)
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
        preferences.onChange = { [weak self] _ in self?.refreshConfiguredSources() }
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
    static func itemsWalking(
        _ folder: URL, depth: Int = 0, fileManager: FileManager = .default
    ) -> [LibraryItem] {
        guard depth <= maximumFolderDepth else { return [] }

        // A folder of photographs is ONE CLIP, and is not descended into — its contents
        // are frames, not clips.
        if ImageSequenceDecoder.isSequence(folder) {
            let frames = ImageSequenceDecoder.frames(in: folder)
            return [LibraryItem(
                name: folder.lastPathComponent, badge: "SEQ", isAvailable: true,
                url: folder, duration: Double(frames.count) / 30.0)]
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [LibraryItem] = []
        let binName = folder.lastPathComponent

        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                found.append(contentsOf: itemsWalking(child, depth: depth + 1,
                                                      fileManager: fileManager))
            } else if playableExtensions.contains(child.pathExtension.lowercased()) {
                var item = libraryItem(for: child)
                item.bin = binName
                found.append(item)
            }
        }

        // A sequence found further down carries the bin of the folder holding it, so it
        // sits with its neighbours rather than alone at the top level.
        return found.map { item in
            var item = item
            if item.bin == nil { item.bin = binName }
            return item
        }
    }

    /// How deep a dropped folder is walked.
    ///
    /// Deep enough for the way people actually file clips — by year, by shoot, by reel —
    /// and shallow enough that a mis-dropped home folder stops rather than grinding.
    static let maximumFolderDepth = 4

    /// actually read.
    private func addToLibrary(_ urls: [URL], library: LibraryPanelBody) {
        var accepted: [LibraryItem] = []
        var rejected: [String] = []

        for url in urls {
            // A folder is expanded one level, because dropping a folder of clips is
            // the normal way to fill a library and refusing it would be pedantic.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {

                // A FOLDER OF PHOTOGRAPHS IS ONE CLIP, not a bin of stills.
                //
                // Checked before the bin path, because the two readings of "a folder"
                // are mutually exclusive and this one is far more specific: a folder of
                // clips is a group of things you choose between, a folder of images is
                // a single thing that plays. Two or more images and no video decides it.
                //
                // From here it is an ordinary clip. It loads through the same door as a
                // DV file, so playback, looping, in and out points and stepping a frame
                // on the beat all work without being written again.
                if ImageSequenceDecoder.isSequence(url) {
                    let frames = ImageSequenceDecoder.frames(in: url)
                    accepted.append(LibraryItem(
                        name: url.lastPathComponent, badge: "SEQ", isAvailable: true,
                        url: url,
                        // 30fps, which is what the decoder gives a stack of pictures.
                        duration: Double(frames.count) / 30.0))
                    Log.info(.app, "\(url.lastPathComponent) is a photo sequence: "
                        + "\(frames.count) frames")
                    continue
                }

                // WALKED ALL THE WAY DOWN, not one level.
                //
                // It used to read only the immediate children, so dropping a folder with
                // any structure inside it — which is how anyone with a real clip library
                // keeps things — silently took the loose files at the top and threw the
                // rest away. Nothing said so. A drop that accepts a folder and quietly
                // ignores most of it is worse than one that refuses.
                //
                // Every folder that holds clips becomes a bin named after ITSELF, so the
                // shape of the library follows the shape on disk. A folder of images
                // along the way is a clip, by the same rule as above, and is not
                // descended into.
                accepted.append(contentsOf: Self.itemsWalking(url))
                continue
            }

            if Self.playableExtensions.contains(url.pathExtension.lowercased()) {
                accepted.append(Self.libraryItem(for: url))
            } else {
                rejected.append(url.lastPathComponent)
            }
        }

        library.addItems(accepted)

        if !rejected.isEmpty {
            presentNotice(
                rejected.count == 1
                    ? "Could not add \(rejected[0])"
                    : "Could not add \(rejected.count) files",
                "Videoboy reads .dv, .mov, .mp4, .m4v, .m2v, .mpg and .ts. "
                    + "These were left out:\n\n\(rejected.joined(separator: "\n"))"
            )
        }
    }

    /// What this build can open. Kept here rather than guessed at each call site.
    static let playableExtensions: Set<String> = [
        "dv", "mov", "mp4", "m4v", "m2v", "mpg", "mpeg", "ts", "m2t", "m2ts"
    ]

    /// A library entry for a file, badged by what it is.
    static func libraryItem(for url: URL) -> LibraryItem {
        let family = DataEffectFamily.forMediaFile(at: url)
        let badge: String
        switch family {
        case .dv: badge = "DV"
        case .mpeg: badge = "MPG"
        case .none: badge = url.pathExtension.uppercased()
        }
        return LibraryItem(
            name: url.lastPathComponent, badge: badge, isAvailable: true, url: url)
    }

    // MARK: - Shift-to-detect

    /// Which slot the crossfaders, shuttles and bus data effects belong to.
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

        // The bus data effects: the wedge on the interchange codec, per bus.
        let busData: [(PreviewPanelBody, String)] = [
            (panels.subMixOneBody, Engine.busCodecOneSlot),
            (panels.subMixTwoBody, Engine.busCodecTwoSlot),
            (panels.programBody, Engine.busCodecProgramSlot)
        ]
        for (body, slot) in busData {
            body.dataAmountFader?.mappingSlot = slot
            body.dataAmountFader?.mappingCode = .corruptAmount
            body.dataModeFader?.mappingSlot = slot
            body.dataModeFader?.mappingCode = .corruptMode
        }

        // The effect chains answer per code, because a code names a different slot
        // on each bus.
        panels.effectsOneBody.mappingSlotForCode = { [weak self] code in self?.slot(forParameter: code, bus: .one) }
        panels.effectsTwoBody.mappingSlotForCode = { [weak self] code in self?.slot(forParameter: code, bus: .two) }
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
        // The status line says what to DO, not only what is happening. "Press a button
        // or pad" is the difference between a learn that works first time and one where
        // a stray knob takes the mapping and nobody knows why.
        shell.statusBar.setMIDIDevice("learning \(code.displayName) — \(accepting.prompt)")
        Log.info(.midi, "detect armed for \(slot)/\(code.rawValue)")
        engine.midi.onDetectCompleted = { [weak self] binding in
            DispatchQueue.main.async {
                guard let self else { return }
                self.shell.statusBar.setMIDIDevice(self.engine.midi.connectedSourceNames.first)
                self.refreshDrivenParameters()
                // Light the effect's MIDI badge when the thing just mapped is that
                // effect's wet/dry. A mapping to one of its individual parameters has
                // nowhere to light up, and that is fine — it is no less real for it,
                // and the fader itself now carries the driven outline.
                self.lightEffectBadge(forSlot: slot, code: code, source: .midi)
                Log.info(.midi, "learned \(binding.source.description) for \(binding.slot)/\(binding.code.rawValue)")
            }
        }
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
            body.onGeneratorSelected = { [weak self] kind in
                self?.setGenerator(kind, channel: letter)
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
                // The most recently chosen mode becomes what a fresh source starts
                // with, so setting it once does not mean setting it four times.
                self?.preferences.preferences.previewFill = fill
                Log.info(.render, "source \(letter) fill is now \(fill.displayName)")
            }
            body.onClipDropped = { [weak self] url, range in
                // The range travels with the drag now, so a dragged clip honours its
                // marks exactly as a double-clicked one does.
                self?.loadClip(url, into: letter, range: range)
            }
            body.onLoopModeChanged = { [weak self] mode in
                self?.engine.sources[letter]?.loopMode = mode
                Log.info(.dv, "source \(letter) loop mode is now \(mode.displayName)")
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
        engine.setChannelSource(.generator, channel: letter)

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
    private func resetParameter(_ code: String, bus: Bus) {
        guard let parameter = ParamCode(rawValue: code) else { return }
        guard let slot = slot(forParameter: parameter, bus: bus) else {
            Log.warn(.param, "no slot is registered for param code \(code); cannot reset it")
            return
        }
        guard let declared = engine.graph.nodes[slot]?.parameters
            .first(where: { $0.code == parameter }) else { return }

        engine.registry.setValue(declared.defaultValue, slot: slot, code: parameter)

        // Move the fader and its readout to match. The write above is the truth; this
        // is the panel catching up, and without it the control sits where it was
        // dragged while the engine is somewhere else — which reads as the key not
        // working.
        let panel = bus == .one
            ? shell.grid.panels.effectsOneBody
            : shell.grid.panels.effectsTwoBody
        if let effect = panel.effects.first(where: { card in
            card.parameters.contains { $0.code == code }
        }) {
            panel.setDisplayedParameterValues(
                effectName: effect.name,
                values: [code: declared.normalise(declared.defaultValue)])
        }
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
        let range = node.playbackRange
        // The caption names WHAT THE CHANNEL SHOWS, which after a swap may not be a file
        // at all. Captioning the clip regardless would put a filename on a channel that
        // is showing the Amiga — a label describing a node the channel is not reading.
        switch engine.channelSourceKinds[letter] ?? .file {
        case .emulator:
            body.setMediaName("Amiga")
        case .generator:
            body.setMediaName(engine.generators[letter]?.generator.displayName ?? "Generator")
        case .capture(let id):
            let name = preferences.preferences.configuredSources.first { $0.id == id }?.name
            body.setMediaName(name ?? "Source")
        case .file:
            body.setMediaName(node.mediaURL.map {
                range == nil ? $0.lastPathComponent : "\($0.lastPathComponent) [trimmed]"
            })
        }
        body.setMarkedRange(range)
        body.setTiming(node.timing)
        body.setScrubPosition(node.normalisedPosition)
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

    /// A plain alert. Used instead of silently doing nothing (SPEC 1.5).
    private func presentNotice(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.runModal()
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
        // Which engine bus each preview's data controls drive.
        let busNames: [String: String] = [
            GraphTopology.subMixOne: "ONE",
            GraphTopology.subMixTwo: "TWO",
            GraphTopology.primary: "PROGRAM"
        ]
        let busSlots: [String: String] = [
            GraphTopology.subMixOne: Engine.busCodecOneSlot,
            GraphTopology.subMixTwo: Engine.busCodecTwoSlot,
            GraphTopology.primary: Engine.busCodecProgramSlot
        ]

        for composite in composites {
            composite.body.onInterchangeChanged = { [weak self] codec in
                guard let self, let bus = busNames[composite.slot] else { return }
                self.engine.setInterchange(codec, forBus: bus)
            }
            composite.body.onScopeKeyPressed = { [weak self] key in
                self?.scopeKeyPressed(key, for: composite.slot, body: composite.body)
            }
            // Light the keys once at startup. Without this the placement and SEND keys
            // sit enabled over a scope that is not running until something is clicked,
            // which invites a click that does nothing.
            composite.body.setScopeSelection(
                scopeSelections[composite.slot] ?? defaultScopeSelection())
            composite.body.onDataParameterChanged = { [weak self] code, value in
                guard let self,
                      let parameter = ParamCode(rawValue: code),
                      let slot = busSlots[composite.slot],
                      let declared = self.engine.graph.nodes[slot]?.parameters
                        .first(where: { $0.code == parameter })
                else { return }
                self.engine.registry.setValue(
                    declared.denormalise(value), slot: slot, code: parameter)
            }
        }
    }

    /// Fades in flight, and cuts waiting for a beat, by bus slot.
    private var activeFades: [String: FadeAutomation] = [:]
    private var pendingCuts: [String: PendingCut] = [:]
    private var beatCutEnabled: [String: Bool] = [:]

    /// Advances any fade or pending cut. Called once per frame.
    ///
    /// A cut waiting on a beat is taken at `fireHostTime`, which is the beat's time
    /// LESS the graph's latency — that is what makes the picture change on the beat
    /// rather than a few frames after it (SPEC 21).
    private func updateFadesAndCuts(from engine: Engine) {
        let now = CACurrentMediaTime()

        for (slot, cut) in pendingCuts where cut.isDue(atHostTime: now) {
            pendingCuts.removeValue(forKey: slot)
            if let rate = cut.rate,
               let code = Self.faderCode(for: slot),
               let current = engine.registry.value(slot: slot, code: code) {
                activeFades[slot] = FadeAutomation(
                    from: current, to: cut.target, duration: rate.seconds, startedAt: now)
                Log.info(.clock, "fade started on beat \(String(format: "%.2f", cut.targetBeat)) for \(slot)")
            } else {
                applyFaderPosition(cut.target, to: slot)
                Log.info(.clock, "cut on beat \(String(format: "%.2f", cut.targetBeat)) taken for \(slot)")
            }
        }

        for (slot, fade) in activeFades {
            applyFaderPosition(fade.position(atHostTime: now), to: slot)
            if fade.isFinished(atHostTime: now) {
                activeFades.removeValue(forKey: slot)
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
            } else {
                applyFaderPosition(target, to: slot)
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
            bus.body.onFade = { [weak self] rate in
                guard let self else { return }
                // Fade always fades. Beat only decides when it starts.
                self.beginMove(
                    on: bus.slot,
                    rate: rate,
                    waitsForBeat: self.beatCutEnabled[bus.slot] ?? false)
            }
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
                guard self.beatCutEnabled[bus.slot] == true else { return }
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

    /// Which slot each param code in the Sub Mix 1 chain belongs to.
    ///
    /// The chain shows effects from several nodes in one list, so a code alone is not
    /// enough to know where a slider's value should land. This table is that mapping,
    /// written out rather than inferred so adding an effect is a one-line change.
    private static let subMixOneSlots: [ParamCode: String] = [
        .scale: Engine.transformSlot,
        .rotation: Engine.transformSlot,
        .flipHorizontal: Engine.transformSlot,
        .flipVertical: Engine.transformSlot,
        .brightness: Engine.colourSlot,
        .contrast: Engine.colourSlot,
        .saturation: Engine.colourSlot,
        .shadow: Engine.colourSlot,
        .highlight: Engine.colourSlot,
        .blackLevel: Engine.colourSlot,
        .whiteLevel: Engine.colourSlot,
        .gamma: Engine.colourSlot,
        // The wedge's codes are NOT here: they live on whichever channel the
        // corruptor card's selector currently points at, resolved dynamically by
        // `slot(forParameter:bus:)` below rather than fixed to one channel.
        // The composite codec and the time-domain effects are bus FX.
        .compositePath: Engine.compositeSlot,
        .compositeCrawl: Engine.compositeSlot,
        .chromaBleed: Engine.compositeSlot,
        .lumaBandwidth: Engine.compositeSlot,
        .tbcWobble: Engine.compositeSlot,
        .headSwitchingNoise: Engine.compositeSlot,
        .chromaSubsampling: Engine.compositeSlot,
        .compositeGeneration: Engine.compositeSlot,
        .echoDecay: Engine.echoSlot,
        .trailLength: Engine.echoSlot,
        .echoThreshold: Engine.echoSlot,
        .feedbackGain: Engine.feedbackSlot,
        .feedbackDelayFrames: Engine.feedbackSlot,
        .feedbackZoom: Engine.feedbackSlot,
        .feedbackRotate: Engine.feedbackSlot,
        .feedbackThreshold: Engine.feedbackSlot,
        .freezeHold: Engine.freezeOneSlot,
        .moshAmount: Engine.moshOneSlot,
        .moshBloom: Engine.moshOneSlot,
        .moshHeal: Engine.moshOneSlot,
        .moshBlocks: Engine.moshOneSlot
    ]

    /// Which slot each param code in the Sub Mix 2 chain belongs to.
    private static let subMixTwoSlots: [ParamCode: String] = [
        .scale: Engine.transformTwoSlot,
        .rotation: Engine.transformTwoSlot,
        .flipHorizontal: Engine.transformTwoSlot,
        .flipVertical: Engine.transformTwoSlot,
        .brightness: Engine.colourTwoSlot,
        .contrast: Engine.colourTwoSlot,
        .saturation: Engine.colourTwoSlot,
        .shadow: Engine.colourTwoSlot,
        .highlight: Engine.colourTwoSlot,
        .blackLevel: Engine.colourTwoSlot,
        .whiteLevel: Engine.colourTwoSlot,
        .gamma: Engine.colourTwoSlot,
        // See the note on subMixOneSlots — the wedge's codes are resolved
        // dynamically now, not fixed to channel C.
        .compositePath: Engine.compositeTwoSlot,
        .compositeCrawl: Engine.compositeTwoSlot,
        .chromaBleed: Engine.compositeTwoSlot,
        .lumaBandwidth: Engine.compositeTwoSlot,
        .tbcWobble: Engine.compositeTwoSlot,
        .headSwitchingNoise: Engine.compositeTwoSlot,
        .chromaSubsampling: Engine.compositeTwoSlot,
        .compositeGeneration: Engine.compositeTwoSlot,
        .echoDecay: Engine.echoTwoSlot,
        .trailLength: Engine.echoTwoSlot,
        .echoThreshold: Engine.echoTwoSlot,
        .feedbackGain: Engine.feedbackTwoSlot,
        .feedbackDelayFrames: Engine.feedbackTwoSlot,
        .feedbackZoom: Engine.feedbackTwoSlot,
        .feedbackRotate: Engine.feedbackTwoSlot,
        .feedbackThreshold: Engine.feedbackTwoSlot,
        .freezeHold: Engine.freezeTwoSlot,
        .moshAmount: Engine.moshTwoSlot,
        .moshBloom: Engine.moshTwoSlot,
        .moshHeal: Engine.moshTwoSlot,
        .moshBlocks: Engine.moshTwoSlot
    ]

    /// Effect card names to the slot they bypass, per bus.
    private static let effectNameToSlot: [String: (one: String, two: String)] = [
        "Transform": (Engine.transformSlot, Engine.transformTwoSlot),
        "Colour": (Engine.colourSlot, Engine.colourTwoSlot),
        "Composite · NTSC": (Engine.compositeSlot, Engine.compositeTwoSlot),
        "Echo / Trails": (Engine.echoSlot, Engine.echoTwoSlot),
        "Feedback": (Engine.feedbackSlot, Engine.feedbackTwoSlot),
        "Freeze": (Engine.freezeOneSlot, Engine.freezeTwoSlot),
        PanelSet.datamoshCardName: (Engine.moshOneSlot, Engine.moshTwoSlot)
    ]

    private func wireEffectChains() {
        shell.grid.panels.effectsOneBody.onParameterChanged = { [weak self] code, value in
            guard let self, let parameter = ParamCode(rawValue: code) else { return }
            guard let slot = self.slot(forParameter: parameter, bus: .one) else {
                Log.warn(.param, "no slot is registered for param code \(code); ignoring the change")
                return
            }
            // The slider is 0...1; the registry scales it into the parameter's range.
            guard let declared = self.engine.graph.nodes[slot]?.parameters
                .first(where: { $0.code == parameter }) else { return }
            self.engine.registry.setValue(declared.denormalise(value), slot: slot, code: parameter)
        }

        shell.grid.panels.effectsOneBody.onParameterReset = { [weak self] code in
            self?.resetParameter(code, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onParameterReset = { [weak self] code in
            self?.resetParameter(code, bus: .two)
        }

        shell.grid.panels.effectsOneBody.onEffectModulationRequested = { [weak self] name, source, view in
            self?.presentModulationMenu(effect: name, source: source, from: view, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onEffectModulationRequested = { [weak self] name, source, view in
            self?.presentModulationMenu(effect: name, source: source, from: view, bus: .two)
        }

        shell.grid.panels.effectsOneBody.onEffectRemoved = { [weak self] name in
            self?.removeEffect(name, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onEffectRemoved = { [weak self] name in
            self?.removeEffect(name, bus: .two)
        }
        shell.grid.panels.effectsOneBody.onEffectAdded = { [weak self] name in
            self?.addEffect(name, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onEffectAdded = { [weak self] name in
            self?.addEffect(name, bus: .two)
        }

        shell.grid.panels.effectsOneBody.onEffectToggled = { [weak self] name, isOn in
            // Bypassing is expressed as wet/dry, so there is one mechanism rather
            // than a separate enable flag threaded through every node.
            self?.setEffectEnabled(name, isOn, bus: .one)
        }
        shell.grid.panels.effectsOneBody.onSweepsChanged = { [weak self] in
            self?.refreshArmedSweeps()
        }
        shell.grid.panels.effectsTwoBody.onSweepsChanged = { [weak self] in
            self?.refreshArmedSweeps()
        }
        shell.grid.panels.effectsOneBody.onCardChannelChanged = { [weak self] name, index in
            self?.cardChannelChanged(name, index, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onCardChannelChanged = { [weak self] name, index in
            self?.cardChannelChanged(name, index, bus: .two)
        }

        // The same chain on TWO, driving its own node instances.
        shell.grid.panels.effectsTwoBody.onParameterChanged = { [weak self] code, value in
            guard let self, let parameter = ParamCode(rawValue: code) else { return }
            guard let slot = self.slot(forParameter: parameter, bus: .two) else {
                Log.warn(.param, "no slot is registered for param code \(code) on bus TWO; ignoring")
                return
            }
            guard let declared = self.engine.graph.nodes[slot]?.parameters
                .first(where: { $0.code == parameter }) else { return }
            self.engine.registry.setValue(declared.denormalise(value), slot: slot, code: parameter)
        }
        shell.grid.panels.effectsTwoBody.onEffectToggled = { [weak self] name, isOn in
            self?.setEffectEnabled(name, isOn, bus: .two)
        }
    }

    /// Every preview's record indicator, by the label it shows.
    private var recordIndicators: [String: MiniRecordIndicator] = [:]
    /// The take in progress, if any.
    private var recording: RecordingSession?

    // MARK: - Per-channel FX (chFX, SPEC 2)
    //
    // A and B each carry their own bitstream wedge, and so do C and D — the graph
    // has always had four independent corruptors, one per ClipSourceNode. What was
    // missing was a way to REACH three of the four: the UI had one corruptor card
    // per bus and it was wired to a single fixed channel (A, and nothing at all for
    // TWO). The card now carries a channel selector, and everything that used to
    // resolve straight to "the" channel resolves through here instead.

    /// Which channel each bus's corruptor card currently targets. 0 is this bus's
    /// first channel letter (A or C), 1 is its second (B or D).
    private var corruptorChannelIndex: [Bus: Int] = [:]

    private func corruptorChannel(bus: Bus) -> String {
        let letters = bus == .one ? ["A", "B"] : ["C", "D"]
        let index = corruptorChannelIndex[bus] ?? 0
        return letters[min(max(index, 0), letters.count - 1)]
    }

    private func corruptorSlot(bus: Bus) -> String {
        Engine.slot(forChannel: corruptorChannel(bus: bus))
    }

    /// Resolves a param code to its slot, for the codes that move depending on which
    /// channel a card's selector points at. Every other code keeps using the static
    /// per-bus tables, which never move.
    private func slot(forParameter code: ParamCode, bus: Bus) -> String? {
        switch code {
        case .corruptAmount, .corruptMode, .corruptRate, .corruptSeed:
            return slots(forEffect: "DV · DIF corruptor", bus: bus).first
        default:
            // A code owned by a card with a channel selector follows that selector,
            // so a fader writes to whichever copy of the effect the card points at.
            // Only when no card claims it does this fall back to the fixed bus table.
            if let owner = Self.cardOwning(code) {
                return slots(forEffect: owner, bus: bus).first
            }
            return bus == .one ? Self.subMixOneSlots[code] : Self.subMixTwoSlots[code]
        }
    }

    /// Resolves an EFFECT's own slot (what its wet/dry, and so its enable switch and
    /// modulation badges, actually address). The corruptor is the one card whose
    /// slot depends on the channel selector; everything else is the static table.
    /// Which effect a card's name refers to, as the suffix used in per-channel slot
    /// names. Nil for the corruptor, which lives on the source node itself.
    private static let effectNameToChannelSuffix: [String: String] = [
        "Transform": "transform",
        "Colour": "colour",
        "Composite · NTSC": "composite",
        "Echo / Trails": "echo",
        "Feedback": "feedback",
        "Freeze": "freeze",
        PanelSet.datamoshCardName: "mosh"
    ]

    private func slot(forEffect name: String, bus: Bus) -> String? {
        slots(forEffect: name, bus: bus).first
    }

    /// Every slot a card currently addresses, which depends on where its A / B / BOTH
    /// selector points.
    ///
    /// A and B address that CHANNEL's own copy of the effect, upstream of the mix.
    /// BOTH addresses the BUS copy, downstream of it — which is genuinely both,
    /// rather than two copies set to the same value, and costs one pass instead of
    /// two. The corruptor is the exception: it lives on the source node itself, so
    /// there is no bus copy and BOTH writes to both channels.
    private func slots(forEffect name: String, bus: Bus) -> [String] {
        let letters = bus == .one ? ["A", "B"] : ["C", "D"]
        let index = cardChannelIndex[name] ?? 0
        let isBoth = index >= letters.count

        if name == "DV · DIF corruptor" {
            return isBoth
                ? letters.map(Engine.slot(forChannel:))
                : [Engine.slot(forChannel: letters[min(index, letters.count - 1)])]
        }
        guard let suffix = Self.effectNameToChannelSuffix[name] else { return [] }
        if isBoth {
            guard let slots = Self.effectNameToSlot[name] else { return [] }
            return [bus == .one ? slots.one : slots.two]
        }
        return [Engine.channelSlot(letters[min(index, letters.count - 1)], suffix)]
    }

    /// Where each card's selector currently points, by card name.
    ///
    /// Colour starts on BOTH (index 2). A grade is nearly always something you want
    /// across the whole bus rather than on one channel, and the BUS copy is the one
    /// declared live at launch — so starting anywhere else would mean the card's
    /// switch and the engine disagreed on the first frame.
    ///
    /// Datamosh starts on BOTH too: the bus copy is where cutting A↔B moshes one
    /// channel's motion onto the other's picture, which is the move people reach for.
    private var cardChannelIndex: [String: Int] = ["Colour": 2, PanelSet.datamoshCardName: 2]

    /// Every copy of an effect on a bus — both channels AND the bus copy — for the
    /// operations that must not leave one of them running.
    private func allSlots(forEffect name: String, bus: Bus) -> [String] {
        let letters = bus == .one ? ["A", "B"] : ["C", "D"]
        if name == "DV · DIF corruptor" {
            return letters.map(Engine.slot(forChannel:))
        }
        guard let suffix = Self.effectNameToChannelSuffix[name] else { return [] }
        var all = letters.map { Engine.channelSlot($0, suffix) }
        if let slots = Self.effectNameToSlot[name] {
            all.append(bus == .one ? slots.one : slots.two)
        }
        return all
    }

    /// Which card owns a param code, so a fader can follow that card's selector.
    ///
    /// Derived from the nodes themselves rather than written out by hand: a list kept
    /// in parallel with the effects is a list that goes stale, and a code missing from
    /// it is a fader that silently writes to the wrong copy.
    private static func cardOwning(_ code: ParamCode) -> String? {
        switch code {
        case .scale, .rotation, .flipHorizontal, .flipVertical, .positionX, .positionY:
            // `.positionX`/`.positionY` are also what a GENERATOR's position uses, and
            // that is not a clash: a code is a label and the SLOT is the address, which
            // is the same reason every effect in the app shares `.wetDry`. The generator
            // reaches its own node through the generator slot and never comes through
            // this resolver, which only answers for faders on an FX card.
            //
            // Leaving them unclaimed here is what made the two new Transform faders
            // enabled-and-dead: unowned codes fall through to a fixed bus table that has
            // no entry for them, so the resolver returned nil and the fader wrote
            // nowhere. Caught by the self-QA rather than by review.
            return "Transform"
        case .brightness, .contrast, .saturation, .shadow,
             .highlight, .blackLevel, .whiteLevel, .gamma:
            return "Colour"
        case .compositePath, .compositeCrawl, .chromaBleed, .lumaBandwidth,
             .tbcWobble, .headSwitchingNoise, .chromaSubsampling, .compositeGeneration:
            return "Composite · NTSC"
        case .echoDecay, .trailLength, .echoThreshold:
            return "Echo / Trails"
        case .feedbackGain, .feedbackDelayFrames, .feedbackZoom,
             .feedbackRotate, .feedbackThreshold:
            return "Feedback"
        case .freezeHold:
            return "Freeze"
        case .moshAmount, .moshBloom, .moshHeal, .moshBlocks:
            return PanelSet.datamoshCardName
        default:
            return nil
        }
    }

    /// The card's selector changed. Three things have to follow it, or the toggle
    /// would move the underlying data without changing what the screen shows: the
    /// Shift-detect address on every fader in the card, the enable switch (each
    /// channel's own bypass, not a single shared one), and the fader/readout values
    /// themselves.
    private func cardChannelChanged(_ name: String, _ index: Int, bus: Bus) {
        cardChannelIndex[name] = index
        if name == "DV · DIF corruptor" { corruptorChannelIndex[bus] = index }
        guard let slot = slots(forEffect: name, bus: bus).first else { return }
        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody

        panel.refreshMappingAddresses()

        // Every parameter the card shows is re-read from whichever node it now points
        // at. A selector that moved the data without changing what the screen shows
        // would be worse than no selector.
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
        case "1": Engine.busCodecOneSlot
        case "2": Engine.busCodecTwoSlot
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
        case .send:
            selection.isSent.toggle()
        }

        // Turning off the last instrument turns everything off, including SEND. A
        // scope that is "sent" but has nothing to draw would leave the send key lit
        // over a picture with nothing on it, which reads as the send being broken.
        if !selection.isShowing {
            selection.isSent = false
        }

        scopeSelections[slot] = selection
        body.setScopeSelection(selection)

        if !selection.isShowing {
            body.preview.setScopeImage(nil, dimsPicture: false)
        }
        updateScopeSend(for: slot, selection: selection)

        Log.info(.app, "scopes on \(slot): "
            + (selection.isShowing
                ? selection.orderedKinds.map(\.displayName).joined(separator: "+")
                    + " · \(selection.placement.displayName)"
                    + (selection.isSent ? " · ON AIR" : "")
                : "off"))
    }

    /// A fresh selection, with the defaults that make the first click do the obvious
    /// thing: over the picture, filling the frame, not on air.
    private func defaultScopeSelection() -> ScopeSelection {
        var selection = ScopeSelection()
        selection.isOverlaid = true
        return selection
    }

    /// Puts the scope into the programme feed, or takes it out.
    ///
    /// Only the PROGRAMME slot can be sent. A sub-mix scope shown on air would be a
    /// scope of a picture that is not the one going out, which is worse than useless —
    /// so the key is there for consistency but reports plainly when it cannot act.
    private func updateScopeSend(for slot: String, selection: ScopeSelection) {
        guard slot == Engine.scopeSourceSlot else {
            if selection.isSent {
                Log.warn(.app, "only PROGRAM's scopes can be sent to air; "
                    + "\(slot) shows the picture before the mix")
            }
            return
        }
        engine.scopeOverlay?.placement = selection.placement
        engine.scopeOverlay?.dimming = selection.isOverlaid ? 0 : 1
        if !selection.isSent {
            engine.scopeOverlay?.setOverlay(nil)
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

    /// Takes an effect out of a chain: bypassed in the graph, card gone from the list.
    ///
    /// The graph itself is fixed, so "remove" means bypass — but the card really does
    /// leave the list, and the chain's Add popup is how it comes back. Removing with
    /// no way to restore would be a trap.
    private func removeEffect(_ name: String, bus: Bus) {
        // Resolved through `slot(forEffect:bus:)`, NOT through the static table.
        // The per-channel corruptor has no entry there — its slot depends on which
        // channel the card is pointed at — so reading the table directly meant the
        // guard fell through and ✕ did nothing at all on the one card in the window
        // most likely to be reached for. The enable switch and the badges were fixed
        // this way already; this was the third path still going the old way.
        // A per-channel card stands for BOTH of its channels, so taking it out has to
        // bypass both. Bypassing only the one the selector happens to point at would
        // leave the other channel corrupting with no card left in the window to
        // reach it — the same unreachable-wedge problem the channel selector was
        // added to solve, reintroduced by the ✕.
        // Removal clears EVERY copy, whatever the selector happens to point at.
        // Taking a card out of the chain while leaving the other channel's copy still
        // running is the unreachable-effect problem all over again.
        let targets = allSlots(forEffect: name, bus: bus)
        guard !targets.isEmpty else {
            Log.warn(.graph, "cannot remove \(name): no slot on bus \(bus == .one ? "ONE" : "TWO")")
            return
        }
        for slot in targets {
            engine.registry.setValue(0, slot: slot, code: .wetDry)
        }
        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
        panel.removeEffect(named: name)
        Log.info(.graph, "\(name) removed from bus \(bus == .one ? "ONE" : "TWO")")
    }

    /// Puts a removed effect back, bypassed, at the end of the chain.
    private func addEffect(_ name: String, bus: Bus) {
        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
        panel.restoreEffect(named: name)
        Log.info(.graph, "\(name) added to bus \(bus == .one ? "ONE" : "TWO")")
    }

    /// Clears sweeps on faders that were aimed at a channel that has just emptied.
    ///
    /// Only the per-channel corruptor's faders follow a channel; the bus effects are
    /// downstream of the mix and keep working whatever is loaded, so their sweeps are
    /// deliberately left alone.
    private func clearSweepsForCorruptor(channel: String) {
        let bus: Bus = ["A", "B"].contains(channel) ? .one : .two
        guard corruptorChannel(bus: bus) == channel else { return }
        let panel = bus == .one
            ? shell.grid.panels.effectsOneBody
            : shell.grid.panels.effectsTwoBody
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
        }
    }

    /// Drives the sweeps once, for checks that step the graph by hand rather than
    /// through the display link.
    func driveSweepsForChecks() { driveSweeps(from: engine) }

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

    /// Drives every armed fader sweep, once a frame.
    ///
    /// A fader with two marks stops being a control you hold and becomes one that
    /// plays itself between them on the clock. The fader owns the marks and the rate;
    /// this owns the clock and the registry, which is the only thing that has both.
    ///
    /// Writes through the SAME path a drag does — the panel's onParameterChanged
    /// closure — so a swept parameter and a dragged one cannot end up taking
    /// different routes into the engine.
    private func driveSweeps(from engine: Engine) {
        guard !armedSweeps.isEmpty else { return }
        guard engine.transport.isRunning else { return }
        let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())

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
                found.append((fader, { [weak panel] value in
                    panel?.onParameterChanged?(code.rawValue, value)
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
        guard scopeRefreshCounter % Self.scopeRefreshInterval == 0 else { return }
        guard let renderer = offscreenRenderer else { return }

        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String, texture: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne, Engine.busCodecOneSlot),
            (panels.subMixTwoBody, GraphTopology.subMixTwo, Engine.busCodecTwoSlot),
            // Scopes must read what actually goes OUT, which is the end of the
            // programme chain — but BEFORE the scope overlay, or a sent scope would
            // measure itself and climb until the trace was solid white.
            (panels.programBody, GraphTopology.primary, Engine.scopeSourceSlot)
        ]

        for composite in composites {
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

            composite.body.preview.scopePlacement = selection.placement
            composite.body.preview.setScopeImage(
                scope, dimsPicture: selection.isOverlaid)

            // SEND: the same image, handed to the node at the end of the programme
            // chain, so it lands in the picture that goes to air rather than only in
            // the preview.
            if selection.isSent, composite.slot == Engine.scopeSourceSlot {
                engine.scopeOverlay?.placement = selection.placement
                engine.scopeOverlay?.dimming = selection.isOverlaid ? 0 : 1
                engine.scopeOverlay?.setOverlay(scope)
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
    private func lightEffectBadge(forSlot slot: String, code: ParamCode, source: ModulationSource) {
        guard code == .wetDry else { return }
        for (name, slots) in Self.effectNameToSlot {
            if slots.one == slot {
                shell.grid.panels.effectsOneBody.setEffectModulationActive(
                    effect: name, source: source, isActive: true)
            }
            if slots.two == slot {
                shell.grid.panels.effectsTwoBody.setEffectModulationActive(
                    effect: name, source: source, isActive: true)
            }
        }
        // The corruptor is not in that static table — its slot depends on which
        // channel its card currently points at — so it is checked separately.
        let corruptorName = "DV · DIF corruptor"
        if slot == corruptorSlot(bus: .one) {
            shell.grid.panels.effectsOneBody.setEffectModulationActive(
                effect: corruptorName, source: source, isActive: true)
        }
        if slot == corruptorSlot(bus: .two) {
            shell.grid.panels.effectsTwoBody.setEffectModulationActive(
                effect: corruptorName, source: source, isActive: true)
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

        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
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
                    for binding in self.engine.registry.bindings
                    where binding.slot == slot && binding.code == parameter {
                        self.engine.registry.unbind(source: binding.source)
                    }
                case "S":
                    self.engine.audioReactivity.remove(slot: slot, code: parameter)
                default:
                    self.engine.lfos.remove(slot: slot, code: parameter)
                }
                panel.setEffectModulationActive(effect: name, source: source, isActive: false)
            }
            // Whatever was chosen, the set of driven parameters may have changed.
            self.refreshDrivenParameters()
        }
    }

    /// Enables or bypasses a named effect on one of the buses.
    private func setEffectEnabled(_ name: String, _ isOn: Bool, bus: Bus) {
        let targets = slots(forEffect: name, bus: bus)
        guard !targets.isEmpty else { return }
        for slot in targets {
            engine.registry.setValue(isOn ? 1 : 0, slot: slot, code: .wetDry)
        }
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
        case .dv:
            controller = EmulationPopover(
                heading: "DV colour",
                summary: "Passes the output through DV: 4:1:1 colour and 8-bit. Each "
                    + "generation re-quantises what the last one produced, the way "
                    + "dubbing a tape does.",
                slot: Engine.busCodecProgramSlot,
                variables: [
                    .init(caption: "Generations", code: .compositeGeneration, range: 0...4),
                    .init(caption: "Damage", code: .corruptAmount),
                    .init(
                        caption: "Rate lock", code: .playbackSpeed,
                        unavailableNote: "Locking output to 29.97 is not built yet; "
                            + "the output mode is negotiated in the Output section.")
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
        shell.grid.panels.settingsBarBody.onOutputDVToggled = { [weak self] isOn in
            self?.engine.isOutputDVEnabled = isOn
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

        for letter in Self.channels {
            // Ask the engine WHICH node this channel is playing from. Reading the
            // file slot unconditionally meant a channel showing a generator drew its
            // empty file node — the generator was reaching the bus and the mix, and
            // the one window that should have shown it stayed blank.
            let slot = engine.sourceSlot(forChannel: letter)
            panels.sourceBodies[letter]?.preview.texture = engine.texture(for: slot)
            panels.sourceBodies[letter]?.preview.present()
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
        panels.subMixOneBody.preview.texture = engine.texture(for: Engine.busCodecOneSlot)
            ?? engine.texture(for: GraphTopology.subMixOne)
        panels.subMixOneBody.preview.present()
        panels.subMixTwoBody.preview.texture = engine.texture(for: Engine.busCodecTwoSlot)
            ?? engine.texture(for: GraphTopology.subMixTwo)
        panels.subMixTwoBody.preview.present()

        // The end of the programme chain, falling back to the mix while the data
        // stage has produced nothing yet.
        let program = engine.texture(for: Engine.outputSlot)
            ?? engine.texture(for: GraphTopology.primary)
        panels.programBody.preview.texture = program
        panels.programBody.preview.present()
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

        updateFadesAndCuts(from: engine)
        updateTallies(from: engine)
        updateScopes(from: engine)
        updateBeatLights(from: engine)
        driveSweeps(from: engine)
        fireActionTriggers(from: engine)
        flipAutomatedButtons(from: engine)

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
