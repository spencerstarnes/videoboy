//
//  AmiberryIPCTests.swift — the control socket, against a real socket.
//
//  A mock would only prove the client talks to the mock. These stand up an actual Unix
//  domain socket and speak Amiberry's protocol back at it, so the framing — tab
//  delimiters, the trailing newline, OK versus ERROR — is tested rather than assumed.
//

import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import VideoboyCore

final class AmiberryIPCTests: XCTestCase {

    /// A stand-in emulator: accepts one connection, records the line, replies.
    private final class FakeSocket {
        let path: String
        private var listener: Int32 = -1
        private(set) var received: [String] = []
        private let lock = NSLock()
        private var reply: String

        init(reply: String) {
            self.reply = reply
            self.path = NSTemporaryDirectory() + "vb-ipc-\(UUID().uuidString).sock"
        }

        func start() {
            unlink(path)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { out in
                    for (i, b) in bytes.enumerated() { out[i] = CChar(b) }
                    out[bytes.count] = 0
                }
            }
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            listen(listener, 4)

            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    let count = read(client, &buffer, buffer.count)
                    if count > 0 {
                        let line = String(decoding: buffer[0..<count], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        lock.lock(); received.append(line); lock.unlock()
                    }
                    let out = Array((reply + "\n").utf8)
                    _ = out.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                    close(client)
                }
            }
            // Give the listener a moment to be bound before anyone connects.
            Thread.sleep(forTimeInterval: 0.05)
        }

        func stop() {
            if listener >= 0 { close(listener) }
            unlink(path)
        }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return received }
    }

    func testAnOKReplyIsParsed() throws {
        let fake = FakeSocket(reply: "OK\tPONG")
        fake.start(); defer { fake.stop() }

        let reply = try AmiberryIPC(path: fake.path).send("PING")
        XCTAssertTrue(reply.isOK)
        XCTAssertEqual(reply.value, "PONG")
    }

    /// The framing is the part most likely to be wrong, and the part a mock would not
    /// catch: tab-separated arguments and a trailing newline.
    func testArgumentsAreTabSeparated() throws {
        let fake = FakeSocket(reply: "OK")
        fake.start(); defer { fake.stop() }

        let states = URL(fileURLWithPath: "/tmp/Application Support/Scala MM400 - 1.uss")
        let config = URL(fileURLWithPath: "/tmp/videoboy-amiga.uae")
        try AmiberryIPC(path: fake.path).saveState(to: states, configuration: config)

        XCTAssertEqual(
            fake.lines.first, "SAVESTATE\t\(states.path)\t\(config.path)",
            "paths with spaces must survive, which is why the protocol is tabs not spaces")
    }

    /// An ERROR reply has to throw rather than be reported as success — this is the
    /// difference between "the state was saved" and a button that lies.
    func testAnErrorReplyThrows() {
        let fake = FakeSocket(reply: "ERROR\tUsage: SAVESTATE <statefile> <configfile>")
        fake.start(); defer { fake.stop() }

        XCTAssertThrowsError(try AmiberryIPC(path: fake.path).send("SAVESTATE")) { error in
            guard case AmiberryIPC.Failure.refused(let why) = error else {
                return XCTFail("expected .refused, got \(error)")
            }
            XCTAssertTrue(why.contains("Usage"), "the emulator's own words survive: \(why)")
        }
    }

    /// A socket that is not there must be a clear failure, not a hang.
    func testAMissingSocketFailsImmediately() {
        let client = AmiberryIPC(path: NSTemporaryDirectory() + "definitely-not-here.sock")
        XCTAssertThrowsError(try client.send("PING")) { error in
            guard case AmiberryIPC.Failure.noSocket = error else {
                return XCTFail("expected .noSocket, got \(error)")
            }
        }
        XCTAssertFalse(client.isAnswering())
    }
}

// MARK: - Against the real emulator

extension AmiberryIPCTests {

    /// Skipped unless an emulator is actually running. When one is, this is the only
    /// test that proves the client speaks to Amiberry rather than to my idea of it.
    func testAgainstARunningAmiberry() throws {
        guard let client = AmiberryIPC.discover() else {
            throw XCTSkip("no emulator running — start one to exercise this")
        }
        let version = client.version()
        XCTAssertNotNil(version, "a running emulator must answer GET_VERSION")
        XCTAssertTrue(
            version?.contains("Amiberry") == true,
            "expected an Amiberry version, got \(version ?? "nil")")
    }
}
