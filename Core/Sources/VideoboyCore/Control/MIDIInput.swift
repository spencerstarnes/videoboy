//
//  MIDIInput.swift — Core MIDI input and the shift-to-detect learn flow (SPEC 7).
//
//  Purpose : Receives MIDI from every connected source, normalises it into
//            `ControlEvent`s, and — when a detect session is armed — captures the
//            next incoming message as a mapping for the touched parameter.
//  Inputs  : Core MIDI packets from hardware and virtual sources.
//  Outputs : `ControlEvent`s, and mappings written into a `ParamRegistry`.
//  Connects: ParamRegistry (where values land), VirtualMIDISource (which the
//            self-tests use to drive it), the status bar (connected device name).
//  Extend  : OSC normalises into the same `ControlEvent`, so it is another producer
//            here, not a parallel system.
//

import Foundation
import CoreMIDI

/// A control message, normalised so MIDI, OSC, keyboard and audio-reactivity are one
/// abstraction rather than N special cases (SPEC 7).
public struct ControlEvent {
    /// Where it came from, which is also what a mapping is keyed on.
    public let source: ControlSource
    /// Value normalised to 0...1.
    public let value: Double

    public init(source: ControlSource, value: Double) {
        self.source = source
        self.value = value
    }
}

/// Receives MIDI and drives the registry.
public final class MIDIInput {

    /// The registry mappings are written into and values delivered to.
    public let registry: ParamRegistry

    /// Names of the sources currently connected, for the status bar.
    public internal(set) var connectedSourceNames: [String] = []

    /// Called on every event, after any mapping has been applied. Used by the UI to
    /// refresh a moved control.
    public var onEvent: ((ControlEvent) -> Void)?

    /// When non-nil, the next incoming event is captured as a mapping for this
    /// target rather than being delivered normally. This is shift-to-detect.
    private var pendingDetect: (slot: String, code: ParamCode)?

    /// Called when a detect completes, so the UI can stop highlighting.
    public var onDetectCompleted: ((ControlBinding) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var isStarted = false

    /// Events decoded on the CoreMIDI thread and not yet delivered on main.
    ///
    /// A buffer rather than one `main.async` per message, because the old shape posted
    /// an unbounded number of blocks: a motorised fader or an LFO on a CC streams
    /// hundreds of messages a second, each one a separate closure allocation and a
    /// separate main-queue wake-up, all competing with the render loop on that same
    /// thread. Now the MIDI thread appends and, only if no drain is already scheduled,
    /// posts exactly one.
    private let incomingLock = NSLock()
    private var incoming: [ControlEvent] = []
    private var isDrainScheduled = false

    public init(registry: ParamRegistry) {
        self.registry = registry
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Opens a Core MIDI client and connects every available source.
    ///
    /// Returns false when Core MIDI is unavailable. That is not fatal: the app runs
    /// with the status bar showing "MIDI: none" (SPEC 1.5).
    @discardableResult
    public func start() -> Bool {
        guard !isStarted else { return true }

        var status = MIDIClientCreateWithBlock("Videoboy" as CFString, &client) { [weak self] _ in
            // A device arriving or leaving invalidates the connection list.
            self?.connectAllSources()
        }
        guard status == noErr else {
            Log.error(.midi, "MIDIClientCreate failed with status \(status); MIDI input unavailable")
            return false
        }

        status = MIDIInputPortCreateWithProtocol(
            client, "Videoboy In" as CFString, ._1_0, &inputPort
        ) { [weak self] eventList, _ in
            self?.handle(eventList: eventList)
        }
        guard status == noErr else {
            Log.error(.midi, "MIDIInputPortCreate failed with status \(status); MIDI input unavailable")
            MIDIClientDispose(client)
            client = 0
            return false
        }

        isStarted = true
        connectAllSources()
        return true
    }

    /// Connects every visible MIDI source to the input port.
    private func connectAllSources() {
        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            let status = MIDIPortConnectSource(inputPort, endpoint, nil)
            // Already-connected is not an error worth reporting on every hotplug.
            if status == noErr || status == kMIDINoConnection {
                names.append(displayName(of: endpoint))
            } else {
                Log.warn(.midi, "could not connect MIDI source \(index): status \(status)")
            }
        }
        // PUBLISHED ON MAIN. `connectAllSources` runs from the CoreMIDI notify block on
        // CoreMIDI's own thread, and the status bar reads this array on the main thread
        // while it refreshes — an unsynchronised read of a Swift array being reassigned
        // underneath it, which is a crash rather than a stale string. The hop costs
        // nothing here: this only runs when a device is plugged or unplugged.
        let connected = names
        DispatchQueue.main.async { [weak self] in
            self?.connectedSourceNames = connected
        }
        Log.info(.midi, "connected \(names.count) MIDI source(s): \(names.joined(separator: ", "))")
    }

    /// The user-visible name of an endpoint.
    private func displayName(of endpoint: MIDIEndpointRef) -> String {
        var property: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &property)
        guard status == noErr, let name = property?.takeRetainedValue() else { return "unknown" }
        return name as String
    }

    // MARK: - Detect / learn

    /// Arms detect for a parameter. The next incoming message is mapped to it.
    ///
    /// This is the second half of shift-to-detect: the UI highlights mappable
    /// controls while Shift is held, the user touches one, and that call lands here.
    public func beginDetect(slot: String, code: ParamCode, accepting: DetectFilter = .anything) {
        pendingDetect = (slot, code)
        detectFilter = accepting
        Log.info(.midi, "detect armed for \(slot)/\(code.rawValue) — \(accepting.prompt)")
    }

    /// What an armed detect will accept.
    ///
    /// ── WHY A BUTTON REFUSES A KNOB ─────────────────────────────────────────────
    ///
    /// Learning is done by touching the control you want, and on a controller that
    /// streams — a motorised fader, a knob being nudged, an LFO on a CC — the first
    /// message to arrive is very often NOT the one you meant. Arm a button, reach for a
    /// pad, and a knob you brushed on the way has already taken the mapping.
    ///
    /// VDMX solves it by listening for the RIGHT KIND of message: arm a button and it
    /// waits for a button. That is this. It is not a nicety — without it, learning a
    /// button on a busy controller is a coin toss.
    public enum DetectFilter: Sendable {
        /// Any control surface message. What a fader wants.
        case anything
        /// Notes only — pads, keys, transport buttons. What a BUTTON wants.
        case notesOnly

        /// Whether an event may complete the detect.
        public func accepts(_ source: ControlSource) -> Bool {
            switch self {
            case .anything:
                return true
            case .notesOnly:
                if case .midiNote = source { return true }
                return false
            }
        }

        /// What to tell the person to do.
        public var prompt: String {
            switch self {
            case .anything: "move a control"
            case .notesOnly: "press a button or pad"
            }
        }
    }

    private var detectFilter: DetectFilter = .anything

    /// Cancels an armed detect.
    public func cancelDetect() {
        if pendingDetect != nil {
            Log.info(.midi, "detect cancelled")
            pendingDetect = nil
            detectFilter = .anything
        }
    }

    /// True while waiting for a control to be moved.
    public var isDetecting: Bool { pendingDetect != nil }

    // MARK: - Event handling

    /// Routes one normalised event: either it completes a detect, or it is delivered
    /// to whatever it is mapped to.
    ///
    /// Exposed so tests can drive the whole flow without Core MIDI, and so OSC can
    /// use the identical path.
    public func handle(event: ControlEvent) {
        if let target = pendingDetect, detectFilter.accepts(event.source) {
            let binding = ControlBinding(source: event.source, slot: target.slot, code: target.code)
            registry.bind(binding)
            pendingDetect = nil
            detectFilter = .anything
            onDetectCompleted?(binding)
            // Deliver the value too, so the parameter jumps to the control's current
            // position rather than waiting for the next move.
            registry.deliver(normalisedValue: event.value, from: event.source)
        } else {
            registry.deliver(normalisedValue: event.value, from: event.source)
        }
        onEvent?(event)
    }

    /// Unpacks a Core MIDI event list into `ControlEvent`s.
    private func handle(eventList: UnsafePointer<MIDIEventList>) {
        let list = eventList.pointee
        var packet = list.packet
        for _ in 0..<list.numPackets {
            // Universal MIDI Packets: one 32-bit word per MIDI 1.0 channel message.
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for wordIndex in 0..<Int(packet.wordCount) where wordIndex < words.count {
                    if let event = Self.decode(word: words[wordIndex]) {
                        // Core MIDI delivers on its own thread; parameter state and
                        // the UI both live on the main thread. Buffered and drained in
                        // one hop — see `incoming`.
                        enqueue(event)
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    /// Takes an event from the CoreMIDI thread and makes sure it gets delivered on main.
    ///
    /// At most one drain is ever in flight: under a dense stream the later messages join
    /// the buffer the pending drain will read, instead of each posting a block of its
    /// own. `[weak self]` because the old version captured `self` strongly from a
    /// background thread, which kept the input alive past any attempt to release it.
    private func enqueue(_ event: ControlEvent) {
        incomingLock.lock()
        incoming.append(event)
        let needsDrain = !isDrainScheduled
        if needsDrain { isDrainScheduled = true }
        incomingLock.unlock()

        guard needsDrain else { return }
        DispatchQueue.main.async { [weak self] in self?.drainIncoming() }
    }

    /// Delivers everything buffered, on the main thread.
    private func drainIncoming() {
        incomingLock.lock()
        let events = incoming
        incoming.removeAll(keepingCapacity: true)
        isDrainScheduled = false
        incomingLock.unlock()

        for event in events { handle(event: event) }
    }

    /// Decodes one Universal MIDI Packet word into a `ControlEvent`.
    ///
    /// Only the two message types that make sense as control surfaces are handled:
    /// Control Change and Note On. Everything else is ignored rather than guessed at.
    static func decode(word: UInt32) -> ControlEvent? {
        // Message type 2 in the top nibble is a MIDI 1.0 channel voice message.
        let messageType = UInt8((word >> 28) & 0xF)
        guard messageType == 0x2 else { return nil }

        let status = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        let channel = status & 0x0F
        // MIDI values are 0...127, so 127 is full scale.
        let normalised = Double(data2) / 127.0

        switch status & 0xF0 {
        case 0xB0:
            return ControlEvent(
                source: .midiControlChange(channel: channel, controller: data1), value: normalised)
        case 0x90:
            return ControlEvent(source: .midiNote(channel: channel, note: data1), value: normalised)
        case 0x80:
            // Note Off is the same address at zero, so a mapped note releases cleanly.
            return ControlEvent(source: .midiNote(channel: channel, note: data1), value: 0)
        default:
            return nil
        }
    }
}
