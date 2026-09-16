//
//  StreamSelfQA.swift — that PROGRAM actually reaches OBS.
//
//  Purpose : The Core tests prove the muxer puts MPEG-TS on a socket. This proves the
//            whole path: a real graph, a real programme texture, read back, encoded
//            and sent, with a receiver on the other end counting what arrives. The
//            two are different claims and the second is the one a performer cares
//            about.
//  Inputs  : none; it builds its own engine and listens on a loopback port.
//  Outputs : selfqa/out/phase-4/obs-stream/ — a result and the frame that was sent.
//  Connects: Engine, OutputRouter, MPEGTSStreamer.
//
//  Loopback only. This check never sends anything off the machine.
//

import Foundation
import Network
import VideoboyCore

enum StreamSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/obs-stream")

        guard MetalContext.shared != nil else {
            check.record(AssertionResult(
                name: "Metal is available", passed: false, detail: "no device"))
            return check.finish()
        }

        let port: UInt16 = 51_240
        var datagrams = 0
        var bytes = 0
        var firstByte: UInt8?
        let lock = NSLock()

        guard let listener = try? NWListener(
            using: .udp, on: NWEndpoint.Port(rawValue: port)!) else {
            check.record(AssertionResult(
                name: "a receiver can listen", passed: false,
                detail: "could not open UDP \(port)"))
            return check.finish()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receiveNext() {
                connection.receiveMessage { data, _, _, _ in
                    if let data, !data.isEmpty {
                        lock.lock()
                        datagrams += 1
                        bytes += data.count
                        if firstByte == nil { firstByte = data[data.startIndex] }
                        lock.unlock()
                    }
                    receiveNext()
                }
            }
            receiveNext()
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        // A real engine with real media, so what is streamed is a picture rather than
        // a test pattern generated for the occasion.
        let engine = Engine()
        let source = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: source.path),
              engine.load(url: source, intoChannel: "A") else {
            check.record(AssertionResult(
                name: "a source loads", passed: false,
                detail: "samples/motion.dv is missing — run scripts/make-fixtures.sh"))
            return check.finish()
        }
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.setPlaying(true, channel: "A")

        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-selfqa-stream.json"))
        store.preferences.destinations = [
            OutputDestination(kind: .obs, name: "OBS", target: "127.0.0.1:\(port)")
        ]
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        let router = OutputRouter(store: store, metal: MetalContext.shared)
        guard let destinationID = store.preferences.destinations.first?.id else {
            return check.finish()
        }
        router.route(.slot(Engine.outputSlot), to: .configured(destinationID))

        check.record(AssertionResult(
            name: "the OBS destination is offered as available once it has a target",
            passed: router.availableOptions().contains {
                if case .configured = $0.destination { return $0.isAvailable }
                return false
            },
            detail: "a destination with no target stays greyed"
        ))

        let renderer = OffscreenRenderer()
        var lastFrame: ImageBuffer?
        let frameCount = 40
        let started = Date()

        for index in 0..<frameCount {
            let context = RenderContext(
                frameIndex: index,
                presentationTime: Double(index) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            let produced = engine.evaluateGraph(context: context)
            router.present { routingSource in
                guard case .slot(let slot) = routingSource else { return nil }
                return produced[slot] ?? produced[GraphTopology.primary]
            }
            if index == frameCount - 1,
               let texture = produced[Engine.outputSlot] ?? produced[GraphTopology.primary] {
                lastFrame = renderer?.readback(texture)
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        router.closeAll()
        // The datagrams are in flight; give the loopback a moment to deliver them.
        Thread.sleep(forTimeInterval: 0.5)

        lock.lock()
        let receivedDatagrams = datagrams
        let receivedBytes = bytes
        let sync = firstByte
        lock.unlock()

        if let lastFrame { try? check.writeImage(lastFrame, named: "streamed-frame.png") }

        check.record(AssertionResult(
            name: "a receiver gets the programme",
            passed: receivedDatagrams > 0,
            detail: "\(receivedDatagrams) datagrams, \(receivedBytes) bytes"
        ))
        check.record(AssertionResult(
            name: "what arrives is a transport stream",
            passed: sync == 0x47,
            detail: sync.map { "first byte 0x\(String($0, radix: 16))" } ?? "nothing arrived"
        ))

        // Encoding cost, stated rather than assumed. A full readback and an MPEG-2
        // encode per frame is the expensive part of this path, and if it cannot keep
        // up with 29.97 that is something to know now rather than during a set.
        let perFrame = elapsed / Double(frameCount) * 1000
        let budget = 1000.0 / StandardDefinition.frameRate
        check.record(AssertionResult(
            name: "streaming keeps inside the frame budget",
            passed: perFrame < budget,
            detail: String(format: "%.1f ms per frame against a %.1f ms budget", perFrame, budget)
        ))
        check.note("loopback only: 127.0.0.1:\(port)")

        return check.finish()
    }
}
