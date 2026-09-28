//
//  ClipPadController.swift — what the Clip Pads DO (docs/specs/clip-pads.md).
//
//  Purpose : Owns the eight pads' behaviour. A dropped clip is kept OPENED for the
//            source its side targets (Engine.preparePad), so a press only swaps it in;
//            straight after, a fresh copy starts opening so the next press is
//            instant too. A press loads (playing or paused per that source's AUTO), a
//            press on the clip already there restarts it, ⌥ loads, plays and cuts the
//            sub-mix to it. Number keys 1–8 press, ⌥+number takes. Pads learn to MIDI
//            (61J–68J press, 61K–68K take, 69J/6AJ side switches) and arm on the beat
//            (⌥⌘, the blue rate box). Saved with the show.
//  Inputs  : the two ClipPadStrips in the toolbar, key presses, the registry (MIDI),
//            the transport (beat arming), library drops.
//  Outputs : loads, restarts and cuts, through ShellController's own load path — the
//            same one a library double-click and ADV use.
//  Connects: ClipPadBank (Core, the rules), ClipPadView/ClipPadStrip, Engine (pad
//            pre-opens), ShellController (loading, auto-play, cutting), LibraryModel.
//  Extend  : keep the render tick out of it: `tick` reads a few registry values and
//            compares numbers; everything that opens a file happens on Engine's queue.
//

import AppKit
import VideoboyCore

final class ClipPadController {

    /// The registry slot the pads' codes live on (they belong to no graph node).
    static let slot = "clipPads"

    private(set) var bank = ClipPadBank()
    private unowned let shell: ShellController
    private let engine: Engine
    private let strips: [ClipPadStrip]
    private var pads: [ClipPadView] { strips.flatMap(\.pads) }
    private var keyMonitor: Any?
    /// The beat interval each armed pad last fired on.
    private var lastFiredInterval: [Int: Double] = [:]

    /// Presses that installed an already-open clip vs. ones that had to open it — self-QA.
    private(set) var instantLoads = 0
    private(set) var waitedLoads = 0
    private(set) var restarts = 0

    init(shell: ShellController, engine: Engine, toolbar: TransportToolbarView) {
        self.shell = shell
        self.engine = engine
        self.strips = [toolbar.leftPads, toolbar.rightPads]

        // The pads' codes, so MIDI learning, mapping and templates see them.
        let momentary = (ParamCode.clipPadPresses + ParamCode.clipPadTakes)
            .map { Parameter(code: $0, range: 0...1, defaultValue: 0) }
        engine.registry.register(slot: Self.slot, parameters: momentary + [
            Parameter(code: .clipPadLeftSide, range: 0...1, defaultValue: 0),
            Parameter(code: .clipPadRightSide, range: 0...1, defaultValue: 0)
        ])

        for strip in strips {
            strip.onSideChanged = { [weak self] side, channel in self?.setChannel(channel, for: side) }
            for pad in strip.pads { wire(pad) }
        }
        installKeyMonitor()
        refreshAll()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func wire(_ pad: ClipPadView) {
        pad.onPress = { [weak self] index, take in self?.press(index, take: take) }
        pad.onArmToggled = { [weak self] index in self?.toggleArmed(index) }
        pad.onRateChanged = { [weak self] index, rate in
            self?.bank.pads[index]?.flipRate = rate
            self?.refresh(index)
        }
        pad.onClear = { [weak self] index in self?.clear(index) }
        pad.canAccept = { [weak self] pasteboard in self?.clip(on: pasteboard) != nil }
        pad.onDrop = { [weak self] index, pasteboard in
            guard let self, let clip = self.clip(on: pasteboard) else { return false }
            self.assign(clip.url, range: clip.range, toPad: index)
            return true
        }
    }

    // MARK: - Assigning

    /// The clip a drag carries: a library entry (with its marks) or a playable file.
    private func clip(on pasteboard: NSPasteboard) -> (url: URL, range: ClosedRange<Double>?)? {
        let library = shell.shell.grid.panels.library
        for id in LibraryBrowser.libraryIDs(on: pasteboard) {
            if let item = library.item(withID: id), let url = item.url {
                return (url, library.markedRange(for: id))
            }
        }
        for url in LibraryBrowser.fileURLs(on: pasteboard) {
            if ImportScan.playableExtensions.contains(url.pathExtension.lowercased()) { return (url, nil) }
        }
        return nil
    }

    /// Puts a clip on a pad and starts opening it for its side's source.
    func assign(_ url: URL, range: ClosedRange<Double>?, toPad index: Int) {
        guard bank.pads.indices.contains(index) else { return }
        bank[pad: index] = ClipPad(path: url.path, inPoint: range?.lowerBound, outPoint: range?.upperBound,
                                   flipRate: bank[pad: index]?.flipRate)
        engine.discardPad(index)
        prepare(index)
        loadThumbnail(index)
        refresh(index)
        Log.info(.app, "pad \(index + 1): \(url.lastPathComponent)")
    }

    func clear(_ index: Int) {
        bank[pad: index] = nil
        engine.discardPad(index)
        lastFiredInterval[index] = nil
        pads[index].thumbnail = nil
        refresh(index)
        Log.info(.app, "pad \(index + 1) cleared")
    }

    /// Opens pad `index`'s clip, in the background, for the source it targets now.
    private func prepare(_ index: Int) {
        guard let pad = bank[pad: index] else { return }
        let target = shell.playbackTarget(for: pad.url)
        engine.preparePad(index, url: target.url, forChannel: bank.channel(forPad: index),
                          knownFrameCount: target.knownFrameCount)
    }

    private func loadThumbnail(_ index: Int) {
        guard let pad = bank[pad: index] else { return }
        let url = pad.url
        ClipThumbnails.shared.request(for: url, at: pad.inPoint ?? 0.1) { [weak self] buffer in
            guard let self, self.bank[pad: index]?.url == url,
                  let buffer, let image = buffer.makeCGImage() else { return }
            self.pads[index].thumbnail = NSImage(cgImage: image, size: NSSize(width: buffer.width, height: buffer.height))
        }
    }

    // MARK: - Sides

    func setChannel(_ channel: String, for side: ClipPadBank.Side) {
        guard bank.setChannel(channel, for: side) else { return }
        strips.first { $0.side == side }?.showChannel(channel)
        // That side's pads now load somewhere else: open them for it.
        for index in 0..<ClipPadBank.count where ClipPadBank.side(ofPad: index) == side { prepare(index) }
        refreshAll()
        Log.info(.app, "pads \(side == .left ? "1–4" : "5–8") now load into \(channel)")
    }

    // MARK: - Pressing

    /// A press: load (or restart); `take` also plays and cuts the sub-mix to it.
    func press(_ index: Int, take: Bool) {
        guard let pad = bank[pad: index] else { return }
        let channel = bank.channel(forPad: index)
        let target = shell.playbackTarget(for: pad.url)
        // The channel may hold the optimized file for this clip; that is still "this clip".
        let held = engine.sources[channel]?.mediaURL.map { $0 == target.url ? pad.url : $0 }
        switch bank.pressAction(pad: index, channelHolds: held) {
        case .empty:
            return
        case .restart:
            restarts += 1
            engine.sources[channel]?.seek(toNormalised: 0)
            // AUTO decides, both ways: a pad that restarts into a paused source stays
            // paused on its first frame; ⌥ always plays.
            shell.setChannelPlaying(channel, take || shell.autoPlays(channel))
            Log.info(.app, "pad \(index + 1): restart \(pad.url.lastPathComponent) on \(channel)")
        case .load:
            var installed = false
            MainThreadCosts.measure("pad.install") {
                installed = engine.installPad(index, url: target.url, intoChannel: channel)
            }
            // AUTO decides play or pause, both ways (a load never inherits the previous
            // clip's state); ⌥ always plays.
            let plays = take || shell.autoPlays(channel)
            if installed {
                instantLoads += 1
                engine.sources[channel]?.playbackRange = pad.range
                MainThreadCosts.measure("pad.clipLoaded") {
                    shell.clipLoaded(pad.url, into: channel, range: pad.range, loaded: true)
                }
                shell.setChannelPlaying(channel, plays)
            } else {
                // Not open yet (just dropped, or the side just switched): the normal
                // off-main-thread load — slower, never blocking.
                waitedLoads += 1
                shell.loadClip(pad.url, into: channel, range: pad.range) { [weak self] loaded in
                    if loaded { self?.shell.setChannelPlaying(channel, plays) }
                }
            }
            // Straight away, the next copy — so pressing it again after another pad
            // took the source is instant too.
            MainThreadCosts.measure("pad.prepare") { prepare(index) }
            Log.info(.app, "pad \(index + 1): \(pad.url.lastPathComponent) into \(channel)"
                + (installed ? "" : " (opened on demand)"))
        }
        if take { MainThreadCosts.measure("pad.cut") { cut(to: channel) } }
        MainThreadCosts.measure("pad.refresh") { refreshLive() }
    }

    /// Takes the sub-mix holding `channel` to it — the bus key for that source.
    private func cut(to channel: String) {
        let panels = shell.shell.grid.panels
        let body = ["A", "B"].contains(channel) ? panels.faderABBody : panels.faderCDBody
        if ["A", "C"].contains(channel) { body.triggerLeftKey() } else { body.triggerRightKey() }
    }

    // MARK: - On the beat (⌥⌘)

    private func toggleArmed(_ index: Int) {
        guard bank[pad: index] != nil else { return }
        let armed = bank.pads[index]?.flipRate != nil
        bank.pads[index]?.flipRate = armed ? nil : PlaybackTiming.fastLadder[0]
        lastFiredInterval[index] = nil
        refresh(index)
        Log.info(.app, "pad \(index + 1) \(armed ? "disarmed" : "armed on the beat")")
    }

    // MARK: - Every frame

    /// MIDI presses, and armed pads on their beat. Cheap: a handful of registry reads.
    func tick() {
        let registry = engine.registry
        for index in 0..<ClipPadBank.count {
            for (code, take) in [(ParamCode.clipPadPresses[index], false), (ParamCode.clipPadTakes[index], true)] {
                guard let value = registry.value(slot: Self.slot, code: code), value > 0.5 else { continue }
                registry.setValue(0, slot: Self.slot, code: code)
                press(index, take: take)
                Log.info(.midi, "pad \(index + 1)\(take ? " take" : "") from a mapping")
            }
        }
        for (code, side) in [(ParamCode.clipPadLeftSide, ClipPadBank.Side.left), (.clipPadRightSide, .right)] {
            guard let value = registry.value(slot: Self.slot, code: code), value > 0.5 else { continue }
            registry.setValue(0, slot: Self.slot, code: code)
            let channels = ClipPadBank.channels(for: side)
            setChannel(bank.channel(for: side) == channels.first ? channels.second : channels.first, for: side)
        }

        guard engine.transport.isRunning else { return }
        let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())
        for index in 0..<ClipPadBank.count {
            guard let rate = bank[pad: index]?.flipRate,
                  let perFire = SweepRate.beatsPerCycle(rate), perFire > 0 else { continue }
            let interval = (beats / perFire).rounded(.down)
            // Arming is not itself a fire: the first boundary AFTER arming is.
            guard let last = lastFiredInterval[index] else { lastFiredInterval[index] = interval; continue }
            guard interval != last else { continue }
            lastFiredInterval[index] = interval
            press(index, take: false)
        }
        if engine.frameIndex % 15 == 0 { refreshLive() }
    }

    // MARK: - Keys

    /// Number keys 1–8 press a pad; ⌥ with it takes. VJ mode only, never while typing,
    /// and never with ⌘ or ⌃ (⌘1–3 are the mode keys).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    /// Handles a key press; true when a pad took it. Separate from the monitor so a
    /// check can deliver a real event through the same code.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !event.isARepeat,
              let characters = event.charactersIgnoringModifiers,
              let index = ClipPadBank.padIndex(forKey: characters),
              let window = shell.shell.window, event.window === window,
              !shell.shell.isHiddenOrHasHiddenAncestor,
              !(window.firstResponder is NSText) else { return false }
        guard bank[pad: index] != nil else { return false }
        press(index, take: flags.contains(.option))
        return true
    }

    // MARK: - Showing state

    private func refreshAll() {
        for index in 0..<ClipPadBank.count { refresh(index) }
        for strip in strips { strip.showChannel(bank.channel(for: strip.side)) }
    }

    private func refresh(_ index: Int) {
        let view = pads[index]
        let pad = bank[pad: index]
        view.hasClip = pad != nil
        view.clipName = pad?.url.lastPathComponent
        view.flipRate = pad?.flipRate
        refreshLive()
    }

    /// Which pads are ready in memory, and which are on their source now.
    private func refreshLive() {
        for index in 0..<ClipPadBank.count {
            let view = pads[index]
            guard let pad = bank[pad: index] else {
                view.isReady = false
                view.isLive = false
                continue
            }
            let channel = bank.channel(forPad: index)
            let target = shell.playbackTarget(for: pad.url)
            view.isReady = engine.isPadReady(index, url: target.url, channel: channel)
                || engine.sources[channel]?.mediaURL == target.url
            view.isLive = engine.sources[channel]?.mediaURL == target.url
        }
    }

    // MARK: - The show

    /// Replaces the pads with a saved set (a template), opening every clip that exists.
    func restore(_ saved: ClipPadBank?) {
        for index in 0..<ClipPadBank.count { engine.discardPad(index) }
        bank = saved ?? ClipPadBank()
        lastFiredInterval = [:]
        for index in 0..<ClipPadBank.count {
            pads[index].thumbnail = nil
            guard let pad = bank[pad: index] else { continue }
            guard FileManager.default.fileExists(atPath: pad.path) else {
                Log.warn(.template, "pad \(index + 1): \(pad.path) is missing; pad left empty")
                bank[pad: index] = nil
                continue
            }
            prepare(index)
            loadThumbnail(index)
        }
        refreshAll()
    }

    /// For self-QA.
    var padViewsForChecks: [ClipPadView] { pads }
    func isReadyForChecks(_ index: Int) -> Bool {
        guard let pad = bank[pad: index] else { return false }
        return engine.isPadReady(index, url: shell.playbackTarget(for: pad.url).url, channel: bank.channel(forPad: index))
    }
}
