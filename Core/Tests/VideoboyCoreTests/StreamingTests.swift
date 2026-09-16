//
//  StreamingTests.swift — that the OBS send actually puts bytes on the wire.
//
//  The interesting claim is not "the type compiles" but "a receiver gets MPEG-TS".
//  So this opens a real UDP socket on localhost, streams frames at it, and checks
//  what arrives is a transport stream — sync byte and all. It also covers the target
//  parsing, because the failure there is sending video somewhere unintended.
//

import XCTest
import Network
@testable import VideoboyCore

final class StreamingTests: XCTestCase {

    /// A bare port must mean localhost. Defaulting the other way would put video on
    /// the network because someone typed a number into a box.
    func testABarePortMeansLocalhost() {
        XCTAssertEqual(MPEGTSStreamer.normalise(target: "9000"), "udp://127.0.0.1:9000")
    }

    func testAHostAndPortIsTakenAsGiven() {
        XCTAssertEqual(
            MPEGTSStreamer.normalise(target: "192.168.1.50:9000"),
            "udp://192.168.1.50:9000")
    }

    func testAnExplicitURLIsLeftAlone() {
        XCTAssertEqual(
            MPEGTSStreamer.normalise(target: "udp://10.0.0.2:1234"),
            "udp://10.0.0.2:1234")
    }

    func testWhitespaceIsNotTakenAsAHostname() {
        XCTAssertEqual(MPEGTSStreamer.normalise(target: "  9000 "), "udp://127.0.0.1:9000")
    }

    /// The real thing: frames in, transport stream out, over a loopback socket.
    func testFramesReachAUDPReceiver() throws {
        let port: UInt16 = 51_234
        let received = expectation(description: "a datagram arrives")
        received.assertForOverFulfill = false

        let listener = try NWListener(
            using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        var firstDatagram: Data?
        let lock = NSLock()

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receiveNext() {
                connection.receiveMessage { data, _, _, _ in
                    if let data, !data.isEmpty {
                        lock.lock()
                        if firstDatagram == nil { firstDatagram = data }
                        lock.unlock()
                        received.fulfill()
                    }
                    receiveNext()
                }
            }
            receiveNext()
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        let streamer: MPEGTSStreamer
        do {
            streamer = try MPEGTSStreamer(
                target: "127.0.0.1:\(port)",
                width: StandardDefinition.width,
                height: StandardDefinition.height)
        } catch {
            return XCTFail("could not open the stream: \(error)")
        }

        // Enough frames to get past the encoder's start-up and force a keyframe out.
        for index in 0..<20 {
            let shade = UInt8(truncatingIfNeeded: index * 11)
            var image = ImageBuffer(
                width: StandardDefinition.width, height: StandardDefinition.height)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    image.setPixel(x: x, y: y, r: shade, g: UInt8(x % 256), b: UInt8(y % 256))
                }
            }
            XCTAssertTrue(streamer.send(image: image), "frame \(index) should have been sent")
        }

        wait(for: [received], timeout: 10)
        streamer.close()

        lock.lock()
        let datagram = firstDatagram
        lock.unlock()

        guard let datagram else { return XCTFail("nothing arrived") }
        // MPEG-TS packets are 188 bytes and start with 0x47. Checking the sync byte
        // is what distinguishes "a receiver got a transport stream" from "a receiver
        // got some bytes", and the latter would pass a weaker test.
        XCTAssertEqual(
            datagram[datagram.startIndex], 0x47,
            "the first byte of an MPEG-TS packet is the sync byte 0x47")
        XCTAssertEqual(
            datagram.count % 188, 0,
            "a UDP datagram of MPEG-TS should be a whole number of 188-byte packets")
        XCTAssertGreaterThan(streamer.framesSent, 0)
    }

    /// A stream to a port nobody is listening on must not take the app down with it.
    ///
    /// UDP is fire-and-forget, so this should succeed quietly rather than fail — the
    /// point of the test is that it does not throw or hang.
    func testStreamingIntoTheVoidIsHarmless() throws {
        let streamer = try MPEGTSStreamer(target: "127.0.0.1:51235")
        var image = ImageBuffer(
            width: StandardDefinition.width, height: StandardDefinition.height)
        image.setPixel(x: 0, y: 0, r: 255, g: 255, b: 255)
        _ = streamer.send(image: image)
        streamer.close()
    }

    /// A frame of the wrong size is refused rather than silently rescaled.
    func testAFrameOfTheWrongSizeIsRefused() throws {
        let streamer = try MPEGTSStreamer(target: "127.0.0.1:51236")
        let wrongSize = ImageBuffer(width: 320, height: 240)
        XCTAssertFalse(streamer.send(image: wrongSize))
        streamer.close()
    }
}
