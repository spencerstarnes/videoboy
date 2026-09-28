//
//  FileTransferTests.swift — Add, Move and Copy do what Lightroom's do, safely.
//

import XCTest
@testable import VideoboyCore

final class FileTransferTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ name: String, _ text: String = "clip") throws -> URL {
        let url = root.appendingPathComponent("src/\(name)")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAddLeavesFilesWhereTheyAre() throws {
        let file = try make("a.mov")
        let result = FileTransfer.transfer([file], method: .add, to: nil)
        XCTAssertEqual(result.urls, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMoveMovesAndCopyCopies() throws {
        let moved = try make("m.mov"), copied = try make("c.mov")
        let dest = root.appendingPathComponent("dest")
        let move = FileTransfer.transfer([moved], method: .move, to: dest)
        XCTAssertEqual(move.urls.map(\.lastPathComponent), ["m.mov"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.mov").path))

        let copy = FileTransfer.transfer([copied], method: .copy, to: dest)
        XCTAssertTrue(copy.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "Copy keeps the original")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("c.mov")), Data("clip".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(FileTransfer.partialFolderName).path),
            "no partial folder left behind")
    }

    /// Two files of the same name in different folders stay apart, each in its folder.
    func testCopyKeepsTheFolderTreeBelowTheRoot() throws {
        let picked = root.appendingPathComponent("src/Picked", isDirectory: true)
        let dest = root.appendingPathComponent("dest")
        var files: [URL] = []
        for path in ["a.mov", "Day 1/clip.mov", "Day 2/clip.mov", "Day 2/Night/b.mov"] {
            let url = picked.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(path.utf8))
            files.append(url)
        }
        let result = FileTransfer.transfer(files, method: .copy, to: dest, keepingFoldersBelow: picked)
        XCTAssertEqual(result.failures, [])
        let landed = result.urls.map { $0.path.replacingOccurrences(of: dest.path + "/", with: "") }
        XCTAssertEqual(landed, ["a.mov", "Day 1/clip.mov", "Day 2/clip.mov", "Day 2/Night/b.mov"])
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("Day 2/clip.mov"), encoding: .utf8),
                       "Day 2/clip.mov", "the right file in the right folder, not a renumbered neighbour")
    }

    func testATakenNameIsNumberedNeverOverwritten() throws {
        let dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("x.mov"))
        let file = try make("x.mov", "new")
        let result = FileTransfer.transfer([file], method: .copy, to: dest)
        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["x 2.mov"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("x.mov")), Data("old".utf8))
    }

    func testAMissingFileFailsAloneAndCancelStops() throws {
        let good = try make("g.mov")
        let missing = root.appendingPathComponent("src/nope.mov")
        let dest = root.appendingPathComponent("dest")
        let result = FileTransfer.transfer([missing, good], method: .copy, to: dest)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["g.mov"])

        let cancelled = FileTransfer.transfer([good], method: .copy, to: dest, isCancelled: { true })
        XCTAssertTrue(cancelled.urls.isEmpty)
    }
}
