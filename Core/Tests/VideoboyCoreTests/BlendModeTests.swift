//
//  BlendModeTests.swift — characterization tests for the layer blend modes (SPEC 12).
//
//  Written during the overnight safety-net phase. `BlendMode` sat at 39% coverage.
//  The maths itself lives in the Metal shader, so what is testable here — and what
//  actually matters — is the CONTRACT: the raw values are an index into the shader's
//  switch, and a saved template stores that index. Renumbering a case silently
//  changes what old work looks like, which is the kind of breakage nobody notices
//  until they reopen a project.
//
//  So the first test below is deliberately the dullest one in the suite: it writes
//  every raw value down. That is the point.
//

import XCTest
@testable import VideoboyCore

final class BlendModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - The shader contract

    /// The file's header says: "Never renumber an existing one — a saved template
    /// stores the index". This is that rule, mechanically enforced. If this test
    /// fails, every template ever saved now renders differently.
    func testRawValuesAreTheShaderContractAndMustNotMove() {
        XCTAssertEqual(BlendMode.normal.rawValue, 0)
        XCTAssertEqual(BlendMode.multiply.rawValue, 1)
        XCTAssertEqual(BlendMode.screen.rawValue, 2)
        XCTAssertEqual(BlendMode.overlay.rawValue, 3)
        XCTAssertEqual(BlendMode.lighten.rawValue, 4)
        XCTAssertEqual(BlendMode.darken.rawValue, 5)
        XCTAssertEqual(BlendMode.difference.rawValue, 6)
        XCTAssertEqual(BlendMode.add.rawValue, 7)
        XCTAssertEqual(BlendMode.subtract.rawValue, 8)
        XCTAssertEqual(BlendMode.colorDodge.rawValue, 9)
        XCTAssertEqual(BlendMode.colorBurn.rawValue, 10)
        XCTAssertEqual(BlendMode.hardLight.rawValue, 11)
        XCTAssertEqual(BlendMode.softLight.rawValue, 12)
        XCTAssertEqual(BlendMode.allCases.count, 13, "a new mode needs a shader branch too")
    }

    func testAllCasesAreInRawValueOrder() {
        // `from(normalised:)` and `normalisedPosition` both index into `allCases`, so
        // a declaration order that did not match the raw values would make the fader
        // and the saved index disagree.
        XCTAssertEqual(BlendMode.allCases.map(\.rawValue), Array(0...12))
    }

    func testEveryModeIsCodableAsItsIndex() throws {
        for mode in BlendMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\(mode.rawValue)")
            XCTAssertEqual(try JSONDecoder().decode(BlendMode.self, from: data), mode)
        }
    }

    // MARK: - Names

    func testEveryModeHasANonEmptyDistinctName() {
        let names = BlendMode.allCases.map(\.displayName)
        XCTAssertFalse(names.contains(where: { $0.isEmpty }))
        XCTAssertEqual(Set(names).count, names.count, "two modes sharing a name would be unpickable")
    }

    // MARK: - The 0...1 parameter (code 65A)

    func testEveryModeRoundTripsThroughItsNormalisedPosition() {
        for mode in BlendMode.allCases {
            XCTAssertEqual(
                BlendMode.from(normalised: mode.normalisedPosition), mode,
                "\(mode.displayName) does not survive a trip through the fader")
        }
    }

    func testTheEndsOfTheFaderAreTheEndsOfTheSet() {
        XCTAssertEqual(BlendMode.from(normalised: 0), .normal)
        XCTAssertEqual(BlendMode.from(normalised: 1), .softLight)
    }

    func testValuesOutsideTheRangeAreClampedRatherThanWrapping() {
        XCTAssertEqual(BlendMode.from(normalised: -5), .normal)
        XCTAssertEqual(BlendMode.from(normalised: 42), .softLight)
    }

    func testTheSweepIsMonotonic() {
        // Dragging the fader one way must never walk the set backwards.
        var previous = -1
        for step in 0...100 {
            let mode = BlendMode.from(normalised: Double(step) / 100.0)
            XCTAssertGreaterThanOrEqual(mode.rawValue, previous)
            previous = mode.rawValue
        }
    }

    func testEveryModeIsReachableBySweepingTheFader() {
        // A mode that no fader position selects is a mode nobody can pick.
        var reached: Set<BlendMode> = []
        for step in 0...1000 {
            reached.insert(BlendMode.from(normalised: Double(step) / 1000.0))
        }
        XCTAssertEqual(reached.count, BlendMode.allCases.count)
    }

    // NOTE: `BlendMode.from(normalised:)` CRASHES on a non-finite input —
    // `Int(Double.nan)` is a fatal error in Swift, not a nil or a zero. That is a
    // confirmed defect, reproduced standalone during this session, and it is fixed in
    // the repair phase; the reproducing test lives in NonFiniteParameterTests once it
    // is safe to run. It is deliberately NOT exercised here, because a trap takes the
    // whole test runner down rather than failing one case.
}
