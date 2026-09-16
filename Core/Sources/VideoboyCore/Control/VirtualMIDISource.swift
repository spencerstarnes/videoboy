//
//  VirtualMIDISource.swift — a fake MIDI deck for self-testing.
//
//  Purpose : Verification channel 3 from docs/SELF-QA-HARNESS.md. Creates a real
//            CoreMIDI virtual source and sends real messages through the system, so
//            detect/learn and mapping can be proven without the physical controller.
//  Inputs   : note/CC numbers and values to send.
//  Outputs  : MIDI packets visible to any CoreMIDI client, including this app's own
//             MIDIInput.
//  Connects : MIDIInput (the receiving side) and ControlEvent/DetectSession.
//  Extend   : add a `send…` method per message type. Keep the byte layout obvious;
//             the whole point is that a failing mapping test is debuggable from here.
//

import Foundation
import CoreMIDI

/// A CoreMIDI virtual source that a test can push messages into.
///
/// Creating this makes a MIDI endpoint visible system-wide for the process lifetime.
/// The name is prefixed so it is never mistaken for hardware in the Display Router
/// or the status bar.
public final class VirtualMIDISource {

    /// The endpoint name as other CoreMIDI clients see it.
    public let name: String

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    /// Creates the virtual source. Returns nil when CoreMIDI refuses — which happens
    /// in sandboxes with no MIDI server, and must not fail a test run.
    public init?(name: String = "Videoboy Self-QA Source") {
        self.name = name

        var status = MIDIClientCreateWithBlock(name as CFString, &client, nil)
        guard status == noErr else {
            Log.error(.midi, "MIDIClientCreate failed with status \(status); virtual MIDI unavailable")
            return nil
        }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else {
            Log.error(.midi, "MIDISourceCreate failed with status \(status); virtual MIDI unavailable")
            MIDIClientDispose(client)
            return nil
        }
        Log.info(.midi, "virtual MIDI source '\(name)' created")
    }

    deinit {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Sends a Control Change message.
    ///
    /// - Parameters:
    ///   - channel: 0...15 (the wire value; the UI shows 1...16).
    ///   - controller: CC number, 0...127.
    ///   - value: 0...127.
    public func sendControlChange(channel: UInt8, controller: UInt8, value: UInt8) {
        // 0xB0 is the Control Change status nibble; the low nibble is the channel.
        send(bytes: [0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F])
    }

    /// Sends a Note On message. A velocity of 0 is a Note Off by convention.
    public func sendNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) {
        send(bytes: [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F])
    }

    /// Sends a Note Off message.
    public func sendNoteOff(channel: UInt8, note: UInt8, velocity: UInt8 = 0) {
        send(bytes: [0x80 | (channel & 0x0F), note & 0x7F, velocity & 0x7F])
    }

    /// Pushes raw status+data bytes out of the virtual source.
    private func send(bytes: [UInt8]) {
        guard source != 0 else { return }
        // CoreMIDI's modern API carries MIDI 1.0 messages inside Universal MIDI
        // Packets, so the three classic bytes are packed into one 32-bit word.
        var word = universalPacketWord(for: bytes)
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        // Timestamp 0 means "deliver immediately".
        _ = MIDIEventListAdd(
            &eventList,
            MemoryLayout<MIDIEventList>.size,
            packet,
            0,
            1,
            &word
        )
        let status = MIDIReceivedEventList(source, &eventList)
        if status != noErr {
            Log.error(.midi, "MIDIReceivedEventList failed with status \(status)")
        }
    }

    /// Packs a 3-byte MIDI 1.0 message into a Universal MIDI Packet word.
    ///
    /// UMP message type 2 (`0x2`) carries MIDI 1.0 channel voice messages; group 0.
    /// Layout is `0x20 << 24 | status << 16 | data1 << 8 | data2`.
    private func universalPacketWord(for bytes: [UInt8]) -> UInt32 {
        let status = bytes.count > 0 ? UInt32(bytes[0]) : 0
        let data1 = bytes.count > 1 ? UInt32(bytes[1]) : 0
        let data2 = bytes.count > 2 ? UInt32(bytes[2]) : 0
        return (UInt32(0x20) << 24) | (status << 16) | (data1 << 8) | data2
    }
}
