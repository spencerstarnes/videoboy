//
//  SavedStateNamingTests.swift — the emulator's save states number themselves.
//
//  Covers the naming rule `EmulatorController` uses when it captures a save state:
//  the first one in an empty directory is 1, and each later one is the next free
//  number rather than something that can collide with what is already there.
//

import XCTest
@testable import VideoboyCore

final class SavedStateNamingTests: XCTestCase {

    private func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("states-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTheFirstStateIsNumberOne() throws {
        let directory = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states = AmigaSaveState(directory: directory)
        XCTAssertEqual(states.nextName(for: "Scala MM400"), "Scala MM400 - 1")
    }

    func testNumbersContinueFromTheHighest() throws {
        let directory = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states = AmigaSaveState(directory: directory)
        for name in ["Scala MM400 - 1", "Scala MM400 - 2", "Scala MM400 - 3"] {
            try Data().write(to: states.url(named: name))
        }
        XCTAssertEqual(states.nextName(for: "Scala MM400"), "Scala MM400 - 4")
    }

    /// The one that matters: deleting a middle state must not make the next save
    /// collide with one that still exists.
    func testADeletedStateDoesNotCauseACollision() throws {
        let directory = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states = AmigaSaveState(directory: directory)
        for name in ["Scala MM400 - 1", "Scala MM400 - 3"] {
            try Data().write(to: states.url(named: name))
        }
        XCTAssertEqual(
            states.nextName(for: "Scala MM400"), "Scala MM400 - 4",
            "counting states rather than reading their numbers would have said 3, "
                + "which already exists")
    }

    /// States for a different program must not affect the numbering of this one.
    func testProgramsAreNumberedSeparately() throws {
        let directory = try emptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let states = AmigaSaveState(directory: directory)
        for name in ["Scala MM400 - 1", "Scala MM400 - 2", "Broadcast Titler - 1"] {
            try Data().write(to: states.url(named: name))
        }
        XCTAssertEqual(states.nextName(for: "Broadcast Titler"), "Broadcast Titler - 2")
        XCTAssertEqual(states.nextName(for: "Scala MM400"), "Scala MM400 - 3")
    }
}
