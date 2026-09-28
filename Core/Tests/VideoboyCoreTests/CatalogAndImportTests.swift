//
//  CatalogAndImportTests.swift — the saved library and the import rules (0.4.7).
//
//  Purpose : The catalog must give back exactly what it was given, survive a reopen,
//            refuse a second writer, and back itself up; the import scan must apply
//            the folder rules; the probe must agree with the decoders about frame
//            counts (a playhead wraps on that number).
//  Connects: Catalog, ImportScan, ImportProgress, ClipProbe, ClipDecoders.
//

import SQLite3
import XCTest
@testable import VideoboyCore

final class CatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func clip(_ n: Int, bin: String? = nil) -> CatalogClip {
        CatalogClip(id: "id-\(n)", path: "/clips/\(n).mov", bookmark: Data([1, 2, UInt8(n)]),
                    name: "\(n).mov", badge: "MOV", bin: bin, duration: Double(n),
                    frameCount: n * 30, frameRate: 29.97, inPoint: 0.25, outPoint: nil, position: n)
    }

    func testWhatIsSavedIsReadBackAfterReopening() throws {
        let url = directory.appendingPathComponent("a.vbcatalog")
        do {
            let catalog = try Catalog(url: url, makesBackups: false)
            catalog.save([clip(1), clip(2, bin: "Reel B"), clip(3)])
            catalog.saveEmptyBins(["Empty"])
            catalog.flush()
        }
        let reopened = try Catalog(url: url, makesBackups: false)
        XCTAssertEqual(reopened.loadClips(), [clip(1), clip(2, bin: "Reel B"), clip(3)])
        XCTAssertEqual(reopened.loadEmptyBins(), ["Empty"])
    }

    /// 0.4.10: the optimized file's link survives a reopen.
    func testTheOptimizedLinkIsKept() throws {
        let url = directory.appendingPathComponent("opt.vbcatalog")
        var linked = clip(1)
        linked.optimizedPath = "/opt/1.m2v"
        linked.optimizedCanvas = "SD NTSC 29.97"
        do {
            let catalog = try Catalog(url: url, makesBackups: false)
            catalog.save([linked, clip(2)])
            catalog.flush()
        }
        let reopened = try Catalog(url: url, makesBackups: false)
        XCTAssertEqual(reopened.loadClips(), [linked, clip(2)])
    }

    /// A catalog written by 0.4.7–0.4.9 (schema 1) opens, keeps its clips, and gains
    /// the optimized columns.
    func testAVersionOneCatalogUpgrades() throws {
        let url = directory.appendingPathComponent("v1.vbcatalog")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let v1 = """
            CREATE TABLE clips (id TEXT PRIMARY KEY, path TEXT NOT NULL, bookmark BLOB,
                name TEXT NOT NULL, badge TEXT NOT NULL, bin TEXT, duration REAL,
                frame_count INTEGER, frame_rate REAL, in_point REAL, out_point REAL,
                position INTEGER NOT NULL);
            CREATE TABLE bins (name TEXT PRIMARY KEY);
            INSERT INTO clips (id, path, name, badge, position) VALUES ('old', '/old.mov', 'old.mov', 'MOV', 0);
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(db, v1, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let catalog = try Catalog(url: url, makesBackups: false)
        let clips = catalog.loadClips()
        XCTAssertEqual(clips.map(\.id), ["old"])
        XCTAssertNil(clips.first?.optimizedPath)
        var updated = clips[0]
        updated.optimizedPath = "/opt/old.mov"
        catalog.save([updated])
        catalog.flush()
        XCTAssertEqual(catalog.loadClips().first?.optimizedPath, "/opt/old.mov")
    }

    func testWritesApplyInOrder() throws {
        let catalog = try Catalog(url: directory.appendingPathComponent("b.vbcatalog"), makesBackups: false)
        catalog.save([clip(1), clip(2)])
        var moved = clip(1, bin: "Moved")
        moved.outPoint = 0.9
        catalog.save([moved])
        catalog.delete(ids: ["id-2"])
        XCTAssertEqual(catalog.loadClips(), [moved])
    }

    func testASecondCopyCannotOpenTheSameCatalog() throws {
        let url = directory.appendingPathComponent("c.vbcatalog")
        do {
            let first = try Catalog(url: url, makesBackups: false)
            XCTAssertThrowsError(try Catalog(url: url, makesBackups: false)) { error in
                guard case CatalogError.inUse = error else { return XCTFail("wrong error: \(error)") }
            }
            withExtendedLifetime(first) {}
        }
        // Released when the first one closes: it opens again.
        XCTAssertNoThrow(try Catalog(url: url, makesBackups: false))
    }

    func testExportIsReadableJSONOfEverything() throws {
        let catalog = try Catalog(url: directory.appendingPathComponent("d.vbcatalog"), makesBackups: false)
        catalog.save([clip(7)])
        let out = directory.appendingPathComponent("export.json")
        try catalog.exportJSON(to: out)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        XCTAssertEqual((json["clips"] as? [[String: Any]])?.first?["name"] as? String, "7.mov")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
    }

    func testOpeningMakesABackupWhenOneIsDue() throws {
        let url = directory.appendingPathComponent("e.vbcatalog")
        do {
            let catalog = try Catalog(url: url, makesBackups: false)
            catalog.save([clip(1)])
            catalog.flush()
        }
        _ = try Catalog(url: url, makesBackups: true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: Catalog.backupDirectory(for: url), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1, "one backup, since none existed")
        // And the backup is a working catalog holding the same clip.
        let restored = try Catalog(url: try XCTUnwrap(backups.first), makesBackups: false)
        XCTAssertEqual(restored.loadClips(), [clip(1)])
    }
}

final class ImportScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-tests-\(UUID().uuidString)", isDirectory: true)
        for path in ["top.mov", "Reel A/one.mov", "Reel A/two.m2v", "Reel B/Deep/three.mov", "Reel B/notes.txt"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAFolderIsWalkedAndItsTreeBecomesNestedBins() {
        let result = ImportScan.scan([root])
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.url.lastPathComponent, $0.bin) })
        XCTAssertEqual(Set(byName.keys), ["top.mov", "one.mov", "two.m2v", "three.mov"])
        let top = root.lastPathComponent
        XCTAssertEqual(byName["top.mov"], top)
        XCTAssertEqual(byName["one.mov"], "\(top)/Reel A")
        XCTAssertEqual(byName["three.mov"], "\(top)/Reel B/Deep", "the folder tree is kept, not flattened")
        XCTAssertTrue(result.includesFolder)
        XCTAssertTrue(result.rejected.isEmpty, "unplayable files inside a folder are not clips, not errors")
    }

    func testDroppingIntoABinNestsTheTreeInsideIt() {
        let result = ImportScan.scan([root], intoBin: "Chosen")
        XCTAssertTrue(result.candidates.allSatisfy { BinPath.isWithin($0.bin ?? "", "Chosen") })
        let three = result.candidates.first { $0.url.lastPathComponent == "three.mov" }
        XCTAssertEqual(three?.bin, "Chosen/\(root.lastPathComponent)/Reel B/Deep")
    }

    /// Import mode hands over FILES, picked from a folder with "Include subfolders".
    func testFilesKeepTheirFoldersBelowTheImportRoot() {
        let files = ["top.mov", "Reel A/one.mov", "Reel B/Deep/three.mov"].map { root.appendingPathComponent($0) }
        let result = ImportScan.scan(files, intoBin: "Shoot", keepingFoldersBelow: root)
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.url.lastPathComponent, $0.bin) })
        XCTAssertEqual(byName["top.mov"], "Shoot")
        XCTAssertEqual(byName["one.mov"], "Shoot/Reel A")
        XCTAssertEqual(byName["three.mov"], "Shoot/Reel B/Deep")
        // "No bin" means no bin.
        let loose = ImportScan.scan(files, intoBin: nil, keepingFoldersBelow: root)
        XCTAssertTrue(loose.candidates.allSatisfy { $0.bin == nil })
    }

    func testADroppedFileThatCannotPlayIsNamed() {
        let result = ImportScan.scan([root.appendingPathComponent("Reel B/notes.txt"),
                                      root.appendingPathComponent("top.mov")])
        XCTAssertEqual(result.rejected, ["notes.txt"])
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertFalse(result.includesFolder)
    }

    func testCancellingStopsTheWalk() {
        // The ✕ is pressed from another thread; the walk polls between entries.
        var polls = 0
        let result = ImportScan.scan([root], isCancelled: { polls += 1; return polls > 3 })
        XCTAssertLessThan(result.candidates.count, 4)
    }
}

final class ImportProgressTests: XCTestCase {

    func testTheStatusBarShowsOnlyWhenTheImportCallsForIt() {
        var progress = ImportProgress()
        progress.found = 3
        XCTAssertFalse(progress.showsStatusBar, "three loose clips: nothing to worry about")
        progress.found = 6
        XCTAssertTrue(progress.showsStatusBar, "more than five clips")

        var folder = ImportProgress()
        folder.includesFolder = true
        XCTAssertTrue(folder.showsStatusBar, "any folder")

        var slow = ImportProgress()
        slow.elapsed = 2.5
        XCTAssertTrue(slow.showsStatusBar, "anything slow")
    }

    func testFoldersAreCountedInTheOrderMet() {
        var progress = ImportProgress()
        for (name, bin) in [("a.mov", "Reel A"), ("b.mov", "Reel A"), ("c.mov", "Reel B")] {
            progress.count(ImportCandidate(url: URL(fileURLWithPath: "/x/\(name)"), bin: bin, isSequence: false))
        }
        XCTAssertEqual(progress.folders, [.init(name: "Reel A", count: 2), .init(name: "Reel B", count: 1)])
        XCTAssertEqual(progress.activeFolder, "Reel B")
        XCTAssertEqual(progress.current, "Reel B/c.mov")
        XCTAssertEqual(progress.found, 3)
    }
}

final class ClipProbeTests: XCTestCase {

    /// The probe's frame count must be the decoder's, or the playhead wraps early or
    /// shows frames that do not exist.
    func testTheProbeAgreesWithEveryDecoder() throws {
        for name in ["motion.m2v", "motion.mov", "hd-h264-2997.mov"] {
            let url = RepoPaths.samples.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no \(name)") }
            let facts = try XCTUnwrap(ClipProbe.facts(of: url), name)
            let decoder = try XCTUnwrap(ClipDecoders.open(url), name)
            XCTAssertEqual(facts.frameCount, decoder.frameCount, name)
            XCTAssertEqual(facts.frameRate, decoder.frameRate, accuracy: 0.001, name)
        }
    }

    /// A known count skips the MPEG picture scan and is used as given.
    func testAKnownFrameCountIsUsedForAnMPEGStream() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no motion.m2v") }
        let counted = try XCTUnwrap(MPEGStreamDecoder(url: url))
        let given = try XCTUnwrap(MPEGStreamDecoder(url: url, knownFrameCount: counted.frameCount))
        XCTAssertEqual(given.frameCount, counted.frameCount)
    }

    func testAnUnreadableFileHasNoFacts() {
        XCTAssertNil(ClipProbe.facts(of: URL(fileURLWithPath: "/nonexistent/nope.mov")))
    }
}
