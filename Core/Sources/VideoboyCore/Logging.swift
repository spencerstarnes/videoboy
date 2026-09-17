//
//  Logging.swift — subsystem-tagged logging.
//
//  Purpose : One logging call shape for the whole app so failures are visible and
//            greppable. SPEC 1.5 forbids swallowed errors; this is what you call
//            instead of dropping one.
//  Inputs  : a `Subsystem` tag and a message.
//  Outputs : a line on stderr, plus an in-memory ring buffer the debug overlay and
//            the self-QA harness can read back.
//  Connects: every subsystem. The self-QA result files embed the tail of the ring
//            so a failed check carries its own log.
//  Extend  : add a case to `Subsystem`. Do not add new log levels; three is enough.
//

import Foundation

/// The subsystem a log line came from. Printed as `[dv]`, `[clock]`, etc.
public enum Subsystem: String, Sendable {
    case app
    case dv
    case bitstream
    case clock
    case midi
    case graph
    case render
    case output
    case selfqa
    case template
    case param
    case titler
}

/// Severity. Deliberately only three levels.
public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// A single captured log line.
public struct LogLine: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let subsystem: Subsystem
    public let message: String

    /// Renders the line the same way it is printed to stderr.
    public var formatted: String {
        let seconds = String(format: "%.3f", timestamp.timeIntervalSince1970)
        return "\(seconds) \(level.rawValue) [\(subsystem.rawValue)] \(message)"
    }
}

/// Process-wide logger. Thread-safe via a plain lock — this is not on the hot path
/// of the render loop, and a lock is easier to reason about than a queue here.
public enum Log {
    private static let lock = NSLock()
    private static var ring: [LogLine] = []
    private static let ringCapacity = 512

    /// When false, nothing is written to stderr (tests stay quiet). The ring still fills.
    public nonisolated(unsafe) static var echoesToStandardError = true

    public static func info(_ subsystem: Subsystem, _ message: @autoclosure () -> String) {
        emit(.info, subsystem, message())
    }

    public static func warn(_ subsystem: Subsystem, _ message: @autoclosure () -> String) {
        emit(.warn, subsystem, message())
    }

    public static func error(_ subsystem: Subsystem, _ message: @autoclosure () -> String) {
        emit(.error, subsystem, message())
    }

    private static func emit(_ level: LogLevel, _ subsystem: Subsystem, _ message: String) {
        let line = LogLine(timestamp: Date(), level: level, subsystem: subsystem, message: message)
        lock.lock()
        ring.append(line)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        let shouldEcho = echoesToStandardError
        lock.unlock()
        if shouldEcho { FileHandle.standardError.write(Data((line.formatted + "\n").utf8)) }
    }

    /// The most recent `count` lines, oldest first. Used by the debug overlay and
    /// embedded into self-QA `result.txt` files so a failure carries its context.
    public static func recent(_ count: Int = 40) -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.suffix(count))
    }

    /// Drops the ring. Tests call this so one test's noise doesn't leak into another's evidence.
    public static func reset() {
        lock.lock()
        ring.removeAll()
        lock.unlock()
    }
}
