//
//  Catalog.swift — the library, saved: one SQLite file, Lightroom-style.
//
//  Purpose : The library lived only in memory — every clip, bin and in/out mark was
//            gone at quit (proposal 09-26 §3). This is where they live now: one
//            catalog file the person can back up or move. Import mode (0.4.9), linked
//            optimized media (0.4.10) and tags (0.5.0) all read and write the SAME
//            records here, which is why it is a database rather than a text file.
//  Inputs  : clip records and bin names from the library.
//  Outputs : the same, read back at launch; weekly backups; a JSON export.
//  Connects: LibraryModel (the app's only writer), ClipProbe (the facts it stores).
//  Extend  : a new fact about a clip is a column, added by a numbered migration in
//            `migrate` — never by editing version 1's CREATE. Bump `schemaVersion`.
//
//  THREADING. Every statement runs on `queue`. Writes are asynchronous and ordered;
//  reads (only at launch) wait. The main thread never touches SQLite directly.
//
//  SAFETY. WAL journaling, so a crash mid-write loses at most the last write, never
//  the file. A lock file stops a second copy of the app writing to the same catalog
//  (`CatalogError.inUse`). Once a week, opening makes a backup (`VACUUM INTO`).
//

import Foundation
import SQLite3

/// One clip as the catalog stores it.
public struct CatalogClip: Equatable, Sendable, Codable {
    /// Stable for the entry's life; the same file may be in two bins as two entries.
    public var id: String
    /// Where the file was when last seen.
    public var path: String
    /// A bookmark, so a moved or renamed file can be found again (relink, 0.4.9).
    public var bookmark: Data?
    public var name: String
    /// DV, MOV, MPG, SEQ…
    public var badge: String
    public var bin: String?
    public var duration: Double?
    /// Measured once at import, so opening a long MPEG file never counts it again.
    public var frameCount: Int?
    public var frameRate: Double?
    /// In and out points, 0...1 of the clip.
    public var inPoint: Double?
    public var outPoint: Double?
    /// Library order.
    public var position: Int
    /// The linked optimized file (0.4.10), when one has been written.
    public var optimizedPath: String?
    /// The canvas it was made for (e.g. "SD NTSC 29.97"); stale when that changes.
    public var optimizedCanvas: String?

    public init(id: String, path: String, bookmark: Data? = nil, name: String, badge: String,
                bin: String? = nil, duration: Double? = nil, frameCount: Int? = nil,
                frameRate: Double? = nil, inPoint: Double? = nil, outPoint: Double? = nil,
                position: Int, optimizedPath: String? = nil, optimizedCanvas: String? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.name = name
        self.badge = badge
        self.bin = bin
        self.duration = duration
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.position = position
        self.optimizedPath = optimizedPath
        self.optimizedCanvas = optimizedCanvas
    }
}

public enum CatalogError: Error, CustomStringConvertible {
    case inUse(URL)
    case cannotOpen(URL, String)

    public var description: String {
        switch self {
        case .inUse(let url):
            "\(url.lastPathComponent) is open in another copy of Videoboy"
        case .cannotOpen(let url, let reason):
            "could not open \(url.lastPathComponent): \(reason)"
        }
    }
}

/// The saved library.
public final class Catalog {

    public let url: URL
    public static let fileExtension = "vbcatalog"
    public static let schemaVersion: Int32 = 2
    /// How often opening makes a backup, and how many are kept.
    public static let backupInterval: TimeInterval = 7 * 24 * 3600
    public static let backupsKept = 5

    private var database: OpaquePointer?
    private let queue: DispatchQueue
    private var lockDescriptor: Int32 = -1

    /// Where the catalog lives when nobody has chosen: next to the person's movies,
    /// where Lightroom keeps its catalog next to their pictures.
    public static var defaultURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Videoboy", isDirectory: true)
            .appendingPathComponent("Videoboy Catalog.\(fileExtension)")
    }

    /// Opens (creating if needed) the catalog at `url`.
    ///
    /// - Parameter makesBackups: false for tests and self-QA, which must never leave
    ///   backup files behind.
    public init(url: URL, makesBackups: Bool = true) throws {
        self.url = url
        self.queue = DispatchQueue(label: "videoboy.catalog", qos: .utility)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // One writer: a lock beside the catalog, held for as long as it is open.
        let lockPath = url.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw CatalogError.cannotOpen(url, "cannot create \(lockPath)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CatalogError.inUse(url)
        }
        lockDescriptor = descriptor

        if makesBackups { Self.backUpIfDue(url) }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            // Every stored property is set by now, so throwing runs `deinit`, which
            // releases the lock — closing it here as well would close it twice.
            throw CatalogError.cannotOpen(url, reason)
        }
        database = handle
        try queue.sync { try migrate() }
        Log.info(.app, "catalog open: \(url.path)")
    }

    deinit {
        queue.sync {
            if let database { sqlite3_close(database) }
            database = nil
        }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        var version: Int32 = 0
        query("PRAGMA user_version") { statement in version = sqlite3_column_int(statement, 0) }
        if version < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    bookmark BLOB,
                    name TEXT NOT NULL,
                    badge TEXT NOT NULL,
                    bin TEXT,
                    duration REAL,
                    frame_count INTEGER,
                    frame_rate REAL,
                    in_point REAL,
                    out_point REAL,
                    position INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS clips_path ON clips(path);
                CREATE TABLE IF NOT EXISTS bins (name TEXT PRIMARY KEY);
                PRAGMA user_version = 1;
                """)
        }
        if version < 2 {
            // 0.4.10: the linked optimized file (Resolve-style: one clip, two files).
            try execute("""
                ALTER TABLE clips ADD COLUMN optimized_path TEXT;
                ALTER TABLE clips ADD COLUMN optimized_canvas TEXT;
                PRAGMA user_version = 2;
                """)
        }
        // Later versions: `if version < 3 { ALTER TABLE … ; PRAGMA user_version = 3 }`.
    }

    // MARK: - Reading (launch)

    /// Every clip, in library order.
    public func loadClips() -> [CatalogClip] {
        queue.sync {
            var clips: [CatalogClip] = []
            query("""
                SELECT id, path, bookmark, name, badge, bin, duration, frame_count, frame_rate,
                       in_point, out_point, position, optimized_path, optimized_canvas
                FROM clips ORDER BY position
                """) { s in
                clips.append(CatalogClip(
                    id: Self.text(s, 0) ?? UUID().uuidString,
                    path: Self.text(s, 1) ?? "",
                    bookmark: Self.blob(s, 2),
                    name: Self.text(s, 3) ?? "",
                    badge: Self.text(s, 4) ?? "",
                    bin: Self.text(s, 5),
                    duration: Self.double(s, 6),
                    frameCount: Self.double(s, 7).map { Int($0) },
                    frameRate: Self.double(s, 8),
                    inPoint: Self.double(s, 9),
                    outPoint: Self.double(s, 10),
                    position: Int(sqlite3_column_int64(s, 11)),
                    optimizedPath: Self.text(s, 12),
                    optimizedCanvas: Self.text(s, 13)))
            }
            return clips
        }
    }

    /// Bins that exist with nothing in them.
    public func loadEmptyBins() -> [String] {
        queue.sync {
            var names: [String] = []
            query("SELECT name FROM bins ORDER BY name") { s in
                if let name = Self.text(s, 0) { names.append(name) }
            }
            return names
        }
    }

    // MARK: - Writing (asynchronous, ordered)

    /// Inserts or replaces whole records, in one transaction.
    public func save(_ clips: [CatalogClip]) {
        guard !clips.isEmpty else { return }
        queue.async { [self] in
            transaction {
                let sql = """
                    INSERT OR REPLACE INTO clips (id, path, bookmark, name, badge, bin, duration,
                        frame_count, frame_rate, in_point, out_point, position,
                        optimized_path, optimized_canvas)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                prepare(sql) { statement in
                    for clip in clips {
                        sqlite3_reset(statement)
                        bind(statement, 1, clip.id)
                        bind(statement, 2, clip.path)
                        bind(statement, 3, clip.bookmark)
                        bind(statement, 4, clip.name)
                        bind(statement, 5, clip.badge)
                        bind(statement, 6, clip.bin)
                        bind(statement, 7, clip.duration)
                        bind(statement, 8, clip.frameCount.map(Double.init))
                        bind(statement, 9, clip.frameRate)
                        bind(statement, 10, clip.inPoint)
                        bind(statement, 11, clip.outPoint)
                        sqlite3_bind_int64(statement, 12, Int64(clip.position))
                        bind(statement, 13, clip.optimizedPath)
                        bind(statement, 14, clip.optimizedCanvas)
                        if sqlite3_step(statement) != SQLITE_DONE { logError("save") }
                    }
                }
            }
        }
    }

    /// Removes records. Files on disk are never touched.
    public func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            transaction {
                prepare("DELETE FROM clips WHERE id = ?") { statement in
                    for id in ids {
                        sqlite3_reset(statement)
                        bind(statement, 1, id)
                        if sqlite3_step(statement) != SQLITE_DONE { logError("delete") }
                    }
                }
            }
        }
    }

    /// Replaces the set of empty bins.
    public func saveEmptyBins(_ names: Set<String>) {
        queue.async { [self] in
            transaction {
                _ = try? execute("DELETE FROM bins")
                prepare("INSERT INTO bins (name) VALUES (?)") { statement in
                    for name in names.sorted() {
                        sqlite3_reset(statement)
                        bind(statement, 1, name)
                        if sqlite3_step(statement) != SQLITE_DONE { logError("bins") }
                    }
                }
            }
        }
    }

    /// Waits for every write queued so far. For quitting and for tests.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Export and backup

    /// The whole catalog as readable JSON — for inspection, never read back.
    public func exportJSON(to destination: URL) throws {
        struct Export: Encodable {
            let schemaVersion: Int32
            let clips: [CatalogClip]
            let emptyBins: [String]
        }
        flush()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(
            schemaVersion: Self.schemaVersion, clips: loadClips(), emptyBins: loadEmptyBins()))
        try data.write(to: destination, options: .atomic)
    }

    /// The backups folder beside the catalog.
    public static func backupDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// Copies the catalog aside if the newest backup is older than the interval, and
    /// keeps only the newest few. Runs before the catalog is opened for writing.
    private static func backUpIfDue(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let directory = backupDirectory(for: url)
        let existing = ((try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == fileExtension }
            .sorted { modified($0) > modified($1) }
        if let newest = existing.first, Date().timeIntervalSince(modified(newest)) < backupInterval {
            return
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.string(
                from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let backup = directory.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent) \(stamp).\(fileExtension)")
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                return
            }
            defer { sqlite3_close(handle) }
            let escaped = backup.path.replacingOccurrences(of: "'", with: "''")
            if sqlite3_exec(handle, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK {
                Log.info(.app, "catalog backed up to \(backup.lastPathComponent)")
                for old in existing.dropFirst(backupsKept - 1) { try? manager.removeItem(at: old) }
            }
        } catch {
            Log.warn(.app, "catalog backup skipped: \(error)")
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - SQLite plumbing (call on `queue`)

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CatalogError.cannotOpen(url, String(cString: sqlite3_errmsg(database)))
        }
    }

    private func transaction(_ body: () -> Void) {
        _ = try? execute("BEGIN IMMEDIATE")
        body()
        if (try? execute("COMMIT")) == nil { logError("commit") }
    }

    private func prepare(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logError("prepare")
            return
        }
        defer { sqlite3_finalize(statement) }
        body(statement)
    }

    private func query(_ sql: String, row: (OpaquePointer) -> Void) {
        prepare(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }
    }

    private func logError(_ what: String) {
        Log.error(.app, "catalog \(what) failed: \(String(cString: sqlite3_errmsg(database)))")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ s: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(s, index, value, -1, Self.transient) } else { sqlite3_bind_null(s, index) }
    }
    private func bind(_ s: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(s, index, value) } else { sqlite3_bind_null(s, index) }
    }
    private func bind(_ s: OpaquePointer, _ index: Int32, _ value: Data?) {
        guard let value else { sqlite3_bind_null(s, index); return }
        _ = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(s, index, raw.baseAddress, Int32(value.count), Self.transient)
        }
    }

    private static func text(_ s: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(s, column) != SQLITE_NULL, let raw = sqlite3_column_text(s, column) else { return nil }
        return String(cString: raw)
    }
    private static func double(_ s: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_double(s, column)
    }
    private static func blob(_ s: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(s, column) != SQLITE_NULL, let raw = sqlite3_column_blob(s, column) else { return nil }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(s, column)))
    }
}
