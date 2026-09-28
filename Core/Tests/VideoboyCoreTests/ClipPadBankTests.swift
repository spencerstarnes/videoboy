//
//  ClipPadBankTests.swift — the Clip Pads' rules.
//
//  Purpose : Which source a pad loads into, when a press restarts instead of loading,
//            the number keys, and that pads survive a template round trip.
//  Inputs   : none.
//  Outputs  : assertions.
//  Connects : ClipPadBank, TemplateDocument, ParamCode.
//

import XCTest
@testable import VideoboyCore

final class ClipPadBankTests: XCTestCase {

    func testSidesAndSwitches() {
        var bank = ClipPadBank()
        XCTAssertEqual((0..<8).map { bank.channel(forPad: $0) }, ["A", "A", "A", "A", "C", "C", "C", "C"])
        XCTAssertTrue(bank.setChannel("B", for: .left))
        XCTAssertTrue(bank.setChannel("D", for: .right))
        XCTAssertEqual(bank.channel(forPad: 3), "B")
        XCTAssertEqual(bank.channel(forPad: 4), "D")
        XCTAssertFalse(bank.setChannel("C", for: .left), "the left side cannot reach C")
        XCTAssertEqual(bank.channel(forPad: 0), "B")
    }

    func testPressLoadsThenRestarts() {
        var bank = ClipPadBank()
        XCTAssertEqual(bank.pressAction(pad: 0, channelHolds: nil), .empty)
        bank[pad: 0] = ClipPad(path: "/clips/a.mov")
        XCTAssertEqual(bank.pressAction(pad: 0, channelHolds: nil), .load)
        XCTAssertEqual(bank.pressAction(pad: 0, channelHolds: URL(fileURLWithPath: "/clips/b.mov")), .load)
        XCTAssertEqual(bank.pressAction(pad: 0, channelHolds: URL(fileURLWithPath: "/clips/./a.mov")), .restart)
    }

    func testNumberKeys() {
        XCTAssertEqual(ClipPadBank.padIndex(forKey: "1"), 0)
        XCTAssertEqual(ClipPadBank.padIndex(forKey: "8"), 7)
        XCTAssertNil(ClipPadBank.padIndex(forKey: "9"))
        XCTAssertNil(ClipPadBank.padIndex(forKey: "0"))
        XCTAssertNil(ClipPadBank.padIndex(forKey: "a"))
    }

    func testCodesAreInTheTable() {
        for code in ParamCode.clipPadPresses + ParamCode.clipPadTakes + [.clipPadLeftSide, .clipPadRightSide] {
            XCTAssertNotNil(ParamCode(rawValue: code.rawValue), "\(code) missing from the table")
        }
        XCTAssertEqual(ParamCode.clipPadPresses.map(\.rawValue).first, "61J")
        XCTAssertEqual(ParamCode.clipPadTakes.map(\.rawValue).last, "68K")
    }

    func testPadsRoundTripInATemplate() throws {
        var bank = ClipPadBank()
        bank[pad: 2] = ClipPad(path: "/clips/c.mov", inPoint: 0.25, outPoint: 0.75,
                               flipRate: .stepped(subdivision: .quarter, frames: 1))
        bank.setChannel("D", for: .right)
        let document = TemplateDocument(clipPads: bank)
        let data = try JSONEncoder().encode(document)
        let back = try JSONDecoder().decode(TemplateDocument.self, from: data)
        XCTAssertEqual(back.clipPads, bank)
        XCTAssertEqual(back.clipPads?[pad: 2]?.range, 0.25...0.75)
        // A template from before pads has none, and still loads.
        let old = try JSONDecoder().decode(TemplateDocument.self, from: Data(#"{"version":3}"#.utf8))
        XCTAssertNil(old.clipPads)
    }
}
