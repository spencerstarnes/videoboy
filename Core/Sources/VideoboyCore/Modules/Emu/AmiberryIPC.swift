//
//  AmiberryIPC.swift — Amiberry's control socket.
//
//  Purpose : Ask the running emulator to do things — save a state, quit, report its
//            version — without anyone touching its window. Amiberry 8 listens on a Unix
//            domain socket and answers a plain-text, tab-delimited protocol.
//  Inputs  : a command word and its arguments.
//  Outputs : the reply, or a thrown error.
//  Connects: EmulatorController (save states), FSUAEHost (the machine it talks to).
//  Extend  : a new command is a new method here. The vocabulary is Amiberry's, not
//            ours — `HELP` over the socket lists it, and the binary carries about a
//            hundred verbs including SEND_KEY, SEND_MOUSE, SET_WINDOW_SIZE and QUIT.
//
//  ── WHAT THIS REPLACES, AND WHY IT IS WORTH HAVING ──────────────────────────────
//
//  Saving a state used to mean a person pressing a key inside the emulator. That is
//  exactly the thing this app exists to avoid: the operator should drive the machine
//  from Videoboy and never have to know the emulator is there.
//
//  Verified by hand against Amiberry 8.3.0 before any of this was written:
//
//      $ printf 'PING\n' | nc -U /tmp/amiberry.sock
//      OK	PONG
//      $ printf 'SAVESTATE\t<path>.uss\t<config>.uae\n' | nc -U /tmp/amiberry.sock
//      OK          → a 540 KB .uss appeared at the path we chose
//
//  The path matters: WE name the file and WE choose the directory, which is what lets
//  states live in Videoboy's own app data and be named after the program rather than
//  landing in whatever the emulator's preferences point at.
//
//  ── THE SOCKET PATH IS NOT FIXED ────────────────────────────────────────────────
//
//  The binary carries "IPC: Default socket in use, using instance ", so a second
//  Amiberry does not get `/tmp/amiberry.sock`. Anything that assumes the default will
//  one day talk to the wrong machine — or to a stale socket left by a crash. So the
//  client PINGS a candidate before trusting it, and `discover` prefers whichever
//  actually answers.
//

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A client for Amiberry's control socket.
public struct AmiberryIPC: Sendable {

    /// Where the socket is.
    public let path: String

    /// How long to wait for a reply. Saving a state writes half a megabyte and pauses
    /// the emulation to do it, so this is generous — but bounded, because a hung
    /// emulator must not hang the caller.
    public var timeout: TimeInterval = 10

    public init(path: String = AmiberryIPC.defaultPath) {
        self.path = path
    }

    /// Where Amiberry puts its socket when nothing else has taken the name.
    public static let defaultPath = "/tmp/amiberry.sock"

    /// What the emulator said back.
    public struct Reply: Equatable, Sendable {
        /// True when the first field was `OK`.
        public let isOK: Bool
        /// Everything after the status, tab-separated as it arrived.
        public let fields: [String]
        /// The whole line, for logging.
        public let raw: String

        /// The first field after the status, which is what most replies carry.
        public var value: String? { fields.first }
    }

    public enum Failure: LocalizedError {
        case noSocket(String)
        case couldNotConnect(String)
        case timedOut
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .noSocket(let path):
                return "No emulator control socket at \(path). The machine may not be "
                    + "running, or may be an older Amiberry without one."
            case .couldNotConnect(let why):
                return "Could not reach the emulator's control socket: \(why)"
            case .timedOut:
                return "The emulator did not answer its control socket in time."
            case .refused(let why):
                return "The emulator refused the command: \(why)"
            }
        }
    }

    // MARK: - Talking to it

    /// Sends one command and returns what came back.
    ///
    /// Arguments are TAB separated, which is what the protocol uses — a path with a
    /// space in it is therefore fine, and this app's states live under "Application
    /// Support", so that is not a hypothetical.
    @discardableResult
    public func send(_ verb: String, _ arguments: [String] = []) throws -> Reply {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure.noSocket(path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.couldNotConnect("socket() failed")
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // The sun_path field is fixed-size; a path that does not fit would be silently
        // truncated and connect to something else entirely.
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.couldNotConnect("the socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { out in
                for (index, byte) in pathBytes.enumerated() { out[index] = CChar(byte) }
                out[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw Failure.couldNotConnect(String(cString: strerror(errno)))
        }

        var window = timeval(
            tv_sec: Int(timeout),
            tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        let line = ([verb] + arguments).joined(separator: "\t") + "\n"
        let outgoing = Array(line.utf8)
        var written = 0
        while written < outgoing.count {
            let sent = outgoing[written...].withUnsafeBufferPointer {
                write(descriptor, $0.baseAddress, $0.count)
            }
            guard sent > 0 else { throw Failure.couldNotConnect("the socket closed while writing") }
            written += sent
        }

        var incoming: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !incoming.contains(UInt8(ascii: "\n")) {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
                throw Failure.couldNotConnect(String(cString: strerror(errno)))
            }
            incoming.append(contentsOf: buffer[0..<count])
        }

        let text = String(decoding: incoming, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = text.components(separatedBy: "\t")
        let status = fields.isEmpty ? "" : fields.removeFirst()
        let reply = Reply(isOK: status == "OK", fields: fields, raw: text)
        guard reply.isOK else {
            throw Failure.refused(fields.joined(separator: " ").isEmpty
                ? text : fields.joined(separator: " "))
        }
        return reply
    }

    /// Whether something is listening and answering.
    public func isAnswering() -> Bool {
        (try? send("PING")) != nil
    }

    // MARK: - The commands this app actually uses

    /// Asks the emulator to write a save state at a path WE choose.
    ///
    /// Both arguments are required — `SAVESTATE <statefile> <configfile>`, confirmed by
    /// the socket's own `HELP` and by it returning `ERROR Usage:` when given one.
    public func saveState(to file: URL, configuration: URL) throws {
        try send("SAVESTATE", [file.path, configuration.path])
    }

    /// Restores one.
    public func loadState(_ file: URL) throws {
        try send("LOADSTATE", [file.path])
    }

    /// Asks it to close cleanly, rather than being killed.
    public func quit() throws {
        try send("QUIT")
    }

    /// What it is, for the panel and the log.
    public func version() -> String? {
        (try? send("GET_VERSION"))?.value
    }

    // MARK: - Finding it

    /// The socket belonging to a running emulator, preferring one that answers.
    ///
    /// A stale socket file survives a crash, so existence is not enough — each
    /// candidate is PINGed. Instance sockets are taken in name order after the default,
    /// which matches the order Amiberry allocates them.
    public static func discover(
        in directory: String = "/tmp", fileManager: FileManager = .default
    ) -> AmiberryIPC? {
        var candidates = [defaultPath]
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        candidates += entries
            .filter { $0.hasPrefix("amiberry") && $0.hasSuffix(".sock") }
            .sorted()
            .map { "\(directory)/\($0)" }

        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate).inserted {
            let client = AmiberryIPC(path: candidate)
            if client.isAnswering() { return client }
        }
        return nil
    }
}
