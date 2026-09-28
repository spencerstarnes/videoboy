//
//  BinPathTests.swift — the rules for bins inside bins.
//
//  Purpose : Nesting is only paths, so every rename, delete and import depends on
//            these few string rules being exactly right.
//  Inputs   : none.
//  Outputs  : assertions.
//  Connects : BinPath.
//

import XCTest
@testable import VideoboyCore

final class BinPathTests: XCTestCase {

    func testPartsParentsAndLeaves() {
        XCTAssertEqual(BinPath.leaf(of: "2019/Shoot A"), "Shoot A")
        XCTAssertEqual(BinPath.parent(of: "2019/Shoot A"), "2019")
        XCTAssertNil(BinPath.parent(of: "2019"))
        XCTAssertEqual(BinPath.ancestors(of: "a/b/c"), ["a", "a/b"])
        XCTAssertEqual(BinPath.join(nil, "a"), "a")
        XCTAssertEqual(BinPath.join("a", "b/c"), "a/b/c")
        XCTAssertEqual(BinPath.join("a", ""), "a")
        XCTAssertEqual(BinPath.display("2019/Shoot A"), "2019 › Shoot A")
    }

    func testWithinIsWholeNamesNotPrefixes() {
        XCTAssertTrue(BinPath.isWithin("Reel/B", "Reel"))
        XCTAssertTrue(BinPath.isWithin("Reel", "Reel"))
        XCTAssertFalse(BinPath.isWithin("Reels/B", "Reel"), "Reels is not inside Reel")
    }

    func testRenameAndDeleteCarryTheBinsInside() {
        XCTAssertEqual(BinPath.replacingPrefix(of: "2019/Shoot A/Take 1", "2019/Shoot A", with: "2019/Day 1"),
                       "2019/Day 1/Take 1")
        XCTAssertEqual(BinPath.replacingPrefix(of: "2019/Shoot A", "2019/Shoot A", with: nil), nil)
        XCTAssertEqual(BinPath.replacingPrefix(of: "2019/Shoot A/Take 1", "2019/Shoot A", with: nil), "Take 1")
        XCTAssertNil(BinPath.replacingPrefix(of: "2020/Shoot A", "2019", with: "x"))
    }

    func testATypedSlashDoesNotNest() {
        XCTAssertEqual(BinPath.sanitisedLeaf(" A/B "), "A-B")
    }

    func testRelativeFolder() {
        let root = URL(fileURLWithPath: "/Volumes/Shoots/Picked")
        XCTAssertEqual(BinPath.relativeFolder(of: root.appendingPathComponent("Day 1/Night/a.mov"), below: root),
                       "Day 1/Night")
        XCTAssertEqual(BinPath.relativeFolder(of: root.appendingPathComponent("a.mov"), below: root), "")
        XCTAssertNil(BinPath.relativeFolder(of: URL(fileURLWithPath: "/elsewhere/a.mov"), below: root))
    }
}
