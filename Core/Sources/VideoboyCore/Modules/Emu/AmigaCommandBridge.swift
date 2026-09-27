//
//  AmigaCommandBridge.swift — how a command gets INSIDE the emulated machine.
//
//  Purpose : A control that produces a script line is useless until the line reaches
//            the program. This is the wire. It writes command files into a drawer the
//            emulated Amiga has mounted, where a small ARexx listener picks them up and
//            hands them to Scala's port.
//  Inputs  : `TitlerCommand`s from `ScalaTitlerPanel`.
//  Outputs : files on disk, and a link state saying whether the Amiga is answering.
//  Connects: ScalaTitlerPanel (above), AmigaSideScripts (the listener at the far end),
//            FSUAEConfiguration (which mounts this drawer as a volume).
//  Extend  : a different transport — a socket, a serial port — implements
//            `AmigaTransport`. The coalescing and the rate limit stay here, because
//            they are properties of the MACHINE at the far end, not of the wire.
//
//  ── WHY A SHARED DRAWER AND NOT SOMETHING CLEVERER ──────────────────────────────
//
//  There is no API into a running emulator. The options are: synthesise keystrokes into
//  its window (fragile, and it steals focus); patch the emulator (GPL, and we may not
//  link it); or use the one channel every Amiga emulator already provides — a host
//  directory mounted as an Amiga volume.
//
//  The third is unglamorous and correct. It needs no cooperation from the emulator, it
//  works identically on FS-UAE, WinUAE and a libretro core, and the Amiga side is
//  twenty lines of ARexx. It also degrades honestly: if nothing is listening, files
//  pile up in a drawer and the link shows as dead, rather than commands vanishing.
//
//  ── THE TWO RULES THAT MATTER ───────────────────────────────────────────────────
//
//  ATOMIC. Write to `.tmp`, then rename to `.vbc`. The listener only looks at `.vbc`,
//  so it can never read half a file. Rename is atomic on every filesystem this will
//  meet; write-then-read is not.
//
//  COALESCED AND RATE-LIMITED. Dragging a fader produces a value per frame. A 68k
//  Amiga cannot service sixty commands a second and neither can a floppy-era
//  filesystem, and — far more importantly — THIS APP'S FIRST RULE IS THAT PLAYBACK
//  NEVER JITTERS. So `send` never touches the disk: it drops the command in a buffer,
//  last-one-wins per verb, and a background queue flushes at a fixed modest rate.
//

import Foundation

/// Where commands go.
public protocol AmigaTransport: AnyObject, Sendable {
    /// Delivers one batch. Called off the main thread.
    func deliver(_ lines: [String], sequence: Int) throws
    /// The sequence numbers the far end has acknowledged.
    func acknowledgedSequences() -> [Int]

    /// The first sequence number this transport may safely use.
    ///
    /// Exists because sequence numbers are FILE NAMES. A fresh bridge starting at 1
    /// every time will happily overwrite `000001.vbc` while the Amiga is still reading
    /// it — which is not a theoretical race: it showed up the first time two commands
    /// were sent from separate runs of the CLI. The transport knows what is already in
    /// the drawer; the bridge does not.
    var startingSequence: Int { get }
}

/// Whether the machine at the far end is answering.
public enum AmigaLinkState: Equatable, Sendable {
    /// Nothing has been sent yet.
    case idle
    /// Commands have gone out; nothing has come back.
    case waiting
    /// The listener is acknowledging, and this is how far behind it is.
    case live(queueDepth: Int)
    /// Something is wrong, in words.
    case failed(String)

    public var isLive: Bool { if case .live = self { return true }; return false }

    /// One line for the panel's link light.
    public var summary: String {
        switch self {
        case .idle: "not started"
        case .waiting: "waiting for the Amiga to answer"
        case .live(let depth): depth == 0 ? "linked" : "linked, \(depth) queued"
        case .failed(let why): why
        }
    }
}

/// Writes commands into a drawer the emulated Amiga can see.
public final class AmigaCommandBridge: @unchecked Sendable {

    /// How often the buffer is flushed to disk.
    ///
    /// Twenty a second. Fast enough that a fader feels connected, slow enough that a
    /// 68k has time to keep up, and — the reason the number is here and not tuned by
    /// feel — far enough from the render loop's 60 that the two never contend.
    public var flushInterval: TimeInterval = 1.0 / 20.0

    private let transport: AmigaTransport
    private let queue = DispatchQueue(label: "com.videoboy.amiga-bridge", qos: .utility)

    /// Commands waiting to go, keyed by verb so the newest wins.
    ///
    /// Keyed by verb because that is the unit Scala replaces: two `FONT` lines in a
    /// row mean only the second one, and sending the first is a wasted round trip on a
    /// machine that has very few to spare. `TEXT` is the exception — see `pendingOrder`.
    private var pending: [String: TitlerCommand] = [:]
    /// The order verbs were first seen in, so a flush preserves it.
    ///
    /// Order matters to Scala: `FONT` then `TEXT` draws at the new size, the other way
    /// round draws at the old one.
    private var pendingOrder: [String] = []
    private var sequence: Int
    private var timer: DispatchSourceTimer?
    private var lastAcknowledged: Int
    /// When the acknowledged sequence last MOVED. Not when an ack was last seen — the
    /// acks are files on disk and they sit there for ever, so their presence says
    /// nothing about whether the machine is still reading.
    private var lastProgress = Date()

    /// How long a queue may sit un-drained before the link is called dead.
    ///
    /// The listener polls several times a second and writes a heartbeat about every two,
    /// so a queue that has not moved in this long is not busy — it is not being read.
    /// Generous enough to ride out the machine being briefly wedged by a big picture
    /// load, short enough that an operator finds out during the song rather than after.
    /// Settable so a test can prove the stall is reported without waiting out a real
    /// eight seconds. A threshold that can only be exercised by sleeping is a threshold
    /// nobody tests.
    public var stallSeconds: TimeInterval = 8

    private let lock = NSLock()
    private var _state: AmigaLinkState = .idle

    /// The link's state. Safe to read from the main thread.
    public var state: AmigaLinkState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Called on the main thread when the link state changes, for the panel's light.
    public var onStateChanged: ((AmigaLinkState) -> Void)?

    public init(transport: AmigaTransport) {
        self.transport = transport
        self.sequence = transport.startingSequence
        self.lastAcknowledged = transport.startingSequence - 1
    }

    deinit { stop() }

    /// Starts flushing.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval)
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            timer.resume()
        }
        setState(.waiting)
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Queues commands. Returns immediately and touches no disk.
    ///
    /// This is called from the UI thread while a fader is being dragged, so it does
    /// the least possible work: take a lock, write into a dictionary, leave.
    public func send(_ commands: [TitlerCommand]) {
        guard !commands.isEmpty else { return }
        lock.lock()
        for command in commands {
            // Keyed by VERB, including TEXT.
            //
            // TEXT used to be keyed by its COORDINATES, so that a page could carry
            // several lines at different positions. Scala does support that — probe
            // 13-two-texts-on-one-page.png shows FIRST and SECOND on one page — but the
            // panel sends exactly one line, and keying by position meant that dragging
            // the Y fader kept EVERY intermediate position as a separate pending line.
            // They all survived the flush and all landed, so the screen filled with a
            // ladder of the same words and only the newest one answered the controls.
            //
            // If several lines are ever offered, key them by their INDEX in the page —
            // never by where they happen to sit, because that is the thing an operator
            // is dragging.
            let key = command.coalesceKey
            if pending[key] == nil { pendingOrder.append(key) }
            pending[key] = command
        }
        lock.unlock()
    }

    /// Sends a batch immediately, in order, bypassing the coalescing buffer.
    ///
    /// For a boot sequence, where every line matters and none may be dropped — the
    /// opposite of a fader drag, and the reason both paths exist.
    public func sendImmediately(_ commands: [TitlerCommand]) {
        guard !commands.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.write(commands.map(\.line))
        }
    }

    /// Writes whatever is buffered. Called on the bridge's own queue.
    ///
    /// Internal rather than private so a test can drive it without waiting on a timer —
    /// a test that sleeps to let a timer fire is a test that fails on a busy machine.
    func flush() {
        lock.lock()
        let batch = pendingOrder.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        pendingOrder.removeAll(keepingCapacity: true)
        lock.unlock()

        // A failed write RETURNS rather than falling through. The first version set
        // `.failed` and then called `updateLinkState()`, which immediately overwrote
        // it with `.waiting` — the error was reported and then swallowed one line
        // later, which is the subtlest way to swallow one.
        if !batch.isEmpty, !write(batch.map(\.line)) { return }
        updateLinkState()
    }

    @discardableResult
    private func write(_ lines: [String]) -> Bool {
        sequence += 1
        do {
            try transport.deliver(lines, sequence: sequence)
            return true
        } catch {
            Log.error(.titler, "could not reach the Amiga: \(error.localizedDescription)")
            setState(.failed("could not write to the shared drawer"))
            return false
        }
    }

    private func updateLinkState() {
        // Nothing acknowledged is only a problem once something has been sent. Before
        // that, silence is simply a machine that has not booted yet.
        guard let newest = transport.acknowledgedSequences().max() else {
            if sequence > 0 { setState(.waiting) }
            return
        }
        if newest > lastAcknowledged {
            lastAcknowledged = newest
            lastProgress = Date()
        }
        let queued = max(sequence - lastAcknowledged, 0)

        // A QUEUE THAT IS NOT DRAINING IS A DEAD LINK, not a live one with a backlog.
        //
        // This used to report `.live` for ever once a single ack had ever arrived. So
        // when the listener inside the Amiga stopped — which it does — the panel went on
        // saying "linked, 40 queued" while every fader and the TAKE button did nothing
        // at all. Observed exactly that: 40 commands written, last ack 41 sequences
        // behind, heartbeat six minutes stale, and the app showing a healthy link.
        //
        // "Linked, N queued" is a reasonable thing to say for a moment. Saying it
        // indefinitely, while the number climbs, is the app lying about the one fact the
        // operator needs.
        if queued > 0, Date().timeIntervalSince(lastProgress) > stallSeconds {
            setState(.failed(
                "the machine has stopped reading commands — \(queued) waiting. "
                    + "STOP and START the machine."))
            return
        }
        setState(.live(queueDepth: queued))
    }

    private func setState(_ new: AmigaLinkState) {
        lock.lock()
        let changed = _state != new
        _state = new
        lock.unlock()
        guard changed else { return }
        Log.info(.titler, "amiga link: \(new.summary)")
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(new) }
    }
}

/// The real transport: a drawer on disk the emulator mounts as a volume.
public final class SharedDrawerTransport: AmigaTransport, @unchecked Sendable {

    /// The host directory the emulator mounts. Commands go in `cmd/`, replies in `ack/`.
    public let root: URL
    public var commandsDirectory: URL { root.appendingPathComponent("cmd") }
    public var acknowledgementsDirectory: URL { root.appendingPathComponent("ack") }

    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        for directory in [root, root.appendingPathComponent("cmd"),
                          root.appendingPathComponent("ack")] {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    /// Throws away commands queued for a machine that is no longer running.
    ///
    /// ── WHY THIS IS NOT HOUSEKEEPING ────────────────────────────────────────────
    ///
    /// The drawer survives the machine. Stop the emulator — or have it die — with
    /// commands still queued, and they are STILL THERE when the next machine boots.
    /// The listener takes them oldest first, so a fresh machine spends its first
    /// minutes replaying a dead session while everything the operator does now waits
    /// behind it. The panel looks erratic: a fader moved ten seconds ago lands, the one
    /// moved just now does not, and the screen shows something nobody asked for.
    ///
    /// A hundred and two stale batches had accumulated here before this was found, and
    /// every measurement taken through them was wrong.
    ///
    /// Acknowledgements are deliberately NOT cleared: they are evidence of what the
    /// last session did, and nothing reads them by age.
    @discardableResult
    public func discardQueuedCommands() -> Int {
        let queued = (try? fileManager.contentsOfDirectory(
            at: commandsDirectory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in queued where file.pathExtension == "vbc" || file.pathExtension == "tmp" {
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            Log.info(.titler, "discarded \(removed) commands queued for a machine that is gone")
        }
        return removed
    }

    public func deliver(_ lines: [String], sequence: Int) throws {
        // Amiga file names: short, no colons or slashes. Zero-padded so the listener
        // can take them in order with a plain alphabetical sort, which is all AmigaDOS
        // `LIST` will give it.
        let name = String(format: "%06d", sequence)
        let temporary = commandsDirectory.appendingPathComponent(name + ".tmp")
        let final = commandsDirectory.appendingPathComponent(name + ".vbc")

        // Newline-terminated, and ISO Latin-1 rather than UTF-8: the Amiga has no idea
        // what UTF-8 is, and a title with an accent in it would otherwise arrive as
        // mojibake. Characters it cannot represent are dropped rather than failing the
        // whole batch.
        let body = lines.joined(separator: "\n") + "\n"
        let data = body.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
        try data.write(to: temporary)
        // The atomic step. Until this rename, the listener sees nothing.
        _ = try fileManager.replaceItemAt(final, withItemAt: temporary)
    }

    public func acknowledgedSequences() -> [Int] {
        sequences(in: acknowledgementsDirectory, suffix: ".ack")
    }

    /// One past the highest number already in either drawer.
    ///
    /// Both drawers, not just the command one: a command that has been consumed leaves
    /// only its acknowledgement behind, and reusing that number would make the host
    /// think a brand-new command had already been answered.
    public var startingSequence: Int {
        let used = sequences(in: commandsDirectory, suffix: ".vbc")
            + sequences(in: acknowledgementsDirectory, suffix: ".ack")
        return (used.max() ?? 0) + 1
    }

    private func sequences(in directory: URL, suffix: String) -> [Int] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.compactMap { name in
            // FS-UAE drops `.uaem` metadata files beside everything it can see, so an
            // exact suffix match matters: `000001.ack.uaem` is not an acknowledgement.
            guard name.hasSuffix(suffix) else { return nil }
            return Int(name.dropLast(suffix.count))
        }
    }

}

/// A transport that keeps everything in memory.
///
/// What the tests drive, and what the EMU panel runs against before an emulator is
/// installed — so the panel, the coalescing and the command vocabulary can all be built
/// and checked with no Amiga in sight.
public final class RecordingTransport: AmigaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [(sequence: Int, lines: [String])] = []
    /// Sequences to report as acknowledged, so link states can be exercised.
    public var acknowledged: [Int] = []
    /// Set to have `deliver` throw, for the failure path.
    public var failsWith: Error?

    public init() {}

    public var batches: [(sequence: Int, lines: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _batches
    }

    /// Every line delivered, flattened — the usual thing a test wants to assert on.
    public var allLines: [String] { batches.flatMap(\.lines) }

    public func deliver(_ lines: [String], sequence: Int) throws {
        if let failsWith { throw failsWith }
        lock.lock(); defer { lock.unlock() }
        _batches.append((sequence, lines))
    }

    public func acknowledgedSequences() -> [Int] { acknowledged }

    /// Always 1: nothing persists between runs, so nothing can collide.
    public var startingSequence: Int { 1 }
}
