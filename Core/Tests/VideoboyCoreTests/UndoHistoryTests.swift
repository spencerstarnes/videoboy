//
//  UndoHistoryTests.swift — that ⌘Z takes back what a person did, and only that.
//
//  The failures that matter: a fader drag that needs sixty presses of ⌘Z, an undo
//  that lands on a value nobody set, a redo that survives a new edit, and a limit
//  that lets the history grow without end.
//

import XCTest
@testable import VideoboyCore

final class UndoHistoryTests: XCTestCase {

    /// A history wired to a dictionary standing in for the registry.
    private func makeHistory(limit: Int = UndoHistory.defaultLimit)
        -> (UndoHistory, () -> [String: Double]) {
        let history = UndoHistory(limit: limit)
        var values: [String: Double] = [:]
        history.apply = { slot, code, value in values["\(slot)|\(code.rawValue)"] = value }
        return (history, { values })
    }

    private func change(_ before: Double, _ after: Double, code: ParamCode = .wetDry,
                        slot: String = "fx1") -> ParameterChange {
        ParameterChange(slot: slot, code: code, before: before, after: after)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testUndoRestoresTheValueBeforeAndRedoPutsItBack() {
        let (history, values) = makeHistory()
        history.record("Wet/Dry", changes: [change(0.2, 0.8)], now: t0)

        XCTAssertEqual(history.undo(), "Wet/Dry")
        XCTAssertEqual(values()["fx1|\(ParamCode.wetDry.rawValue)"], 0.2)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(), "Wet/Dry")
        XCTAssertEqual(values()["fx1|\(ParamCode.wetDry.rawValue)"], 0.8)
    }

    func testADragIsOneStep() {
        let (history, values) = makeHistory()
        for i in 1...60 {
            let before = Double(i - 1) / 60, after = Double(i) / 60
            history.record("Wet/Dry", changes: [change(before, after)],
                           now: t0.addingTimeInterval(Double(i) * 0.016))
        }
        XCTAssertEqual(history.steps.count, 1)
        XCTAssertEqual(history.steps[0].changes[0].before, 0)
        XCTAssertEqual(history.steps[0].changes[0].after, 1)
        history.undo()
        XCTAssertEqual(values()["fx1|\(ParamCode.wetDry.rawValue)"], 0)
    }

    func testAPauseOrADifferentControlStartsANewStep() {
        let (history, _) = makeHistory()
        history.record("Wet/Dry", changes: [change(0, 0.5)], now: t0)
        history.record("Wet/Dry", changes: [change(0.5, 0.6)], now: t0.addingTimeInterval(2))
        history.record("Blend Mode", changes: [change(0, 3, code: .blendMode)],
                       now: t0.addingTimeInterval(2.1))
        XCTAssertEqual(history.steps.map(\.name), ["Wet/Dry", "Wet/Dry", "Blend Mode"])
    }

    func testADragBackToWhereItStartedLeavesNothing() {
        let (history, _) = makeHistory()
        history.record("Wet/Dry", changes: [change(0.3, 0.7)], now: t0)
        history.record("Wet/Dry", changes: [change(0.7, 0.3)], now: t0.addingTimeInterval(0.1))
        XCTAssertTrue(history.steps.isEmpty)
        XCTAssertFalse(history.canUndo)
    }

    func testNoOpAndNonFiniteChangesAreNotRecorded() {
        let (history, _) = makeHistory()
        history.record("Wet/Dry", changes: [change(0.5, 0.5)], now: t0)
        history.record("Wet/Dry", changes: [change(0.5, .nan)], now: t0)
        XCTAssertTrue(history.steps.isEmpty)
    }

    func testANewEditDiscardsRedo() {
        let (history, _) = makeHistory()
        history.record("A", changes: [change(0, 1)], now: t0)
        history.record("B", changes: [change(1, 2)], now: t0.addingTimeInterval(5))
        history.undo()
        XCTAssertTrue(history.canRedo)
        history.record("C", changes: [change(1, 3)], now: t0.addingTimeInterval(10))
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.steps.map(\.name), ["A", "C"])
    }

    func testAnEditRightAfterUndoIsItsOwnStep() {
        let (history, _) = makeHistory()
        history.record("Wet/Dry", changes: [change(0, 0.5)], now: t0)
        history.undo()
        history.redo()
        history.record("Wet/Dry", changes: [change(0.5, 0.9)], now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(history.steps.count, 2)
    }

    func testRevertWalksToAnyEntry() {
        let (history, values) = makeHistory()
        let key = "fx1|\(ParamCode.wetDry.rawValue)"
        for i in 0..<5 {
            history.record("Step \(i)", changes: [change(Double(i), Double(i + 1))],
                           now: t0.addingTimeInterval(Double(i) * 5))
        }
        history.revert(to: 2)
        XCTAssertEqual(history.position, 2)
        XCTAssertEqual(values()[key], 2)
        history.revert(to: 0)
        XCTAssertEqual(values()[key], 0)
        history.revert(to: 5)
        XCTAssertEqual(values()[key], 5)
        XCTAssertEqual(history.steps.count, 5, "reverting must not lose steps")
    }

    func testMultiValueStepsUndoInReverse() {
        let (history, values) = makeHistory()
        history.record("AVE-5 Position", changes: [
            change(0, 1, code: .positionX), change(0, 2, code: .positionY)
        ], now: t0)
        history.undo()
        XCTAssertEqual(values()["fx1|\(ParamCode.positionX.rawValue)"], 0)
        XCTAssertEqual(values()["fx1|\(ParamCode.positionY.rawValue)"], 0)
    }

    func testTheLimitDropsTheOldest() {
        let (history, _) = makeHistory(limit: 10)
        for i in 0..<25 {
            history.record("Step \(i)", changes: [change(Double(i), Double(i + 1))],
                           now: t0.addingTimeInterval(Double(i) * 5))
        }
        XCTAssertEqual(history.steps.count, 10)
        XCTAssertEqual(history.steps.first?.name, "Step 15")
        XCTAssertEqual(history.position, 10)

        history.revert(to: 4)
        history.limit = 10
        XCTAssertEqual(history.position, 4)
    }

    func testLoweringTheLimitTrimsAndTheLimitIsClamped() {
        let (history, _) = makeHistory(limit: 100)
        for i in 0..<40 {
            history.record("Step \(i)", changes: [change(Double(i), Double(i + 1))],
                           now: t0.addingTimeInterval(Double(i) * 5))
        }
        history.limit = 20
        XCTAssertEqual(history.steps.count, 20)
        XCTAssertEqual(history.position, 20)
        history.limit = 0
        XCTAssertEqual(history.limit, UndoHistory.limitRange.lowerBound)
        XCTAssertEqual(history.steps.count, UndoHistory.limitRange.lowerBound)
        history.limit = 1_000_000
        XCTAssertEqual(history.limit, UndoHistory.limitRange.upperBound)
    }

    func testClearForgetsEverything() {
        let (history, _) = makeHistory()
        history.record("A", changes: [change(0, 1)], now: t0)
        history.clear()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testTheUndoLimitSurvivesARestartAndAnOutOfRangeFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")

        XCTAssertEqual(PreferenceStore(fileURL: url).preferences.undoLimit, UndoHistory.defaultLimit)
        PreferenceStore(fileURL: url).preferences.undoLimit = 250
        XCTAssertEqual(PreferenceStore(fileURL: url).preferences.undoLimit, 250)

        try Data(#"{"undoLimit": 99999}"#.utf8).write(to: url)
        XCTAssertEqual(PreferenceStore(fileURL: url).preferences.undoLimit,
                       UndoHistory.limitRange.upperBound)
    }
}
