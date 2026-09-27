//
//  ABRollTests.swift — A/B ROLL's sides and ADV's next-clip rules.
//

import XCTest
@testable import VideoboyCore

final class ABRollTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/abroll/\(name)") }
    private let always: (URL) -> Bool = { _ in true }

    func testATakeKnowsWhichSideIsIncoming() {
        XCTAssertEqual(ABRoll.take(channels: ("A", "B"), target: 1), .init(incoming: "B", outgoing: "A"))
        XCTAssertEqual(ABRoll.take(channels: ("A", "B"), target: 0), .init(incoming: "A", outgoing: "B"))
        XCTAssertEqual(ABRoll.take(channels: ("C", "D"), target: 1), .init(incoming: "D", outgoing: "C"))
    }

    func testTheQueueAlwaysWins() {
        var picker = NextClipPicker()
        var queue = Playlist()
        queue.append(url: url("q1.mov"))
        let library = [LibraryCandidate(url: url("l1.mov"), bin: nil)]
        let pick = picker.pick(queue: &queue, library: library, fallback: .inOrder,
                               onAir: nil, outgoing: nil, isLoadable: always)
        XCTAssertEqual(pick, .init(url: url("q1.mov"), fromQueue: true, fallback: nil))
        XCTAssertTrue(queue.isEmpty, "taken off the queue")
    }

    func testInOrderWalksDownSkipsOnAirAndWraps() {
        var picker = NextClipPicker()
        var queue = Playlist()
        let library = ["1", "2", "3"].map { LibraryCandidate(url: url("\($0).mov"), bin: nil) }
        var picks: [String] = []
        for _ in 0..<4 {
            let pick = picker.pick(queue: &queue, library: library, fallback: .inOrder,
                                   onAir: url("2.mov"), outgoing: nil, isLoadable: always)
            picks.append(pick?.url.lastPathComponent ?? "nil")
        }
        XCTAssertEqual(picks, ["1.mov", "3.mov", "1.mov", "3.mov"], "never the on-air clip; back to the top")
    }

    func testOffLoadsNothingAndMissingFilesAreSkipped() {
        var picker = NextClipPicker()
        var queue = Playlist()
        queue.append(url: url("gone.mov"))
        let library = [LibraryCandidate(url: url("1.mov"), bin: nil)]
        XCTAssertNil(picker.pick(queue: &queue, library: library, fallback: .off,
                                 onAir: nil, outgoing: nil, isLoadable: { $0.lastPathComponent != "gone.mov" }))
    }

    func testShuffleDealsEveryClipOnceBeforeRepeating() {
        var picker = NextClipPicker()
        var queue = Playlist()
        let library = (1...5).map { LibraryCandidate(url: url("\($0).mov"), bin: nil) }
        var seen: [String] = []
        var seed = 0.0
        for _ in 0..<5 {
            seed += 0.37
            let pick = picker.pick(queue: &queue, library: library, fallback: .shuffleAll,
                                   onAir: nil, outgoing: nil, isLoadable: always,
                                   random: { seed.truncatingRemainder(dividingBy: 1) })
            seen.append(pick?.url.lastPathComponent ?? "nil")
        }
        XCTAssertEqual(Set(seen).count, 5, "five picks, five different clips: \(seen)")
    }

    func testShuffleBinStaysInTheOutgoingClipsBin() {
        var picker = NextClipPicker()
        var queue = Playlist()
        let library = [LibraryCandidate(url: url("t1.dv"), bin: "Tapes"),
                       LibraryCandidate(url: url("t2.dv"), bin: "Tapes"),
                       LibraryCandidate(url: url("p1.mov"), bin: "Phone")]
        for _ in 0..<4 {
            let pick = picker.pick(queue: &queue, library: library, fallback: .shuffleBin,
                                   onAir: nil, outgoing: LibraryCandidate(url: url("t1.dv"), bin: "Tapes"),
                                   isLoadable: always)
            XCTAssertTrue(pick?.url.lastPathComponent.hasPrefix("t") ?? false, "stayed in Tapes: \(String(describing: pick))")
        }
    }

    func testTheClipLeavingAirIsNotCuedAgain() {
        var picker = NextClipPicker()
        var queue = Playlist()
        let library = ["1", "2", "3"].map { LibraryCandidate(url: url("\($0).mov"), bin: nil) }
        let pick = picker.pick(queue: &queue, library: library, fallback: .inOrder,
                               onAir: url("2.mov"), outgoing: LibraryCandidate(url: url("1.mov"), bin: nil),
                               isLoadable: always)
        XCTAssertEqual(pick?.url.lastPathComponent, "3.mov")
    }
}
