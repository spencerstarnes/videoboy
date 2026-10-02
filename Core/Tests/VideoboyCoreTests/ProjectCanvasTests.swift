//
//  ProjectCanvasTests.swift — the project canvas setting (proposal §6).
//
//  Purpose : The stored canvas must round-trip, a canvas this build does not offer
//            must read as SD NTSC rather than fail the whole preferences file, and the
//            vertical canvas must place pictures the right way round.
//  Connects: ProjectCanvas, Preferences, CanvasGeometry.
//

import XCTest
@testable import VideoboyCore

final class ProjectCanvasTests: XCTestCase {

    func testVerticalIsNineBySixteen() {
        let vertical = ProjectCanvas.vertical.geometry
        XCTAssertEqual(vertical.width, 1080)
        XCTAssertEqual(vertical.height, 1920)
        XCTAssertEqual(vertical.displayAspect, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertTrue(ProjectCanvas.vertical.isAvailable)
        XCTAssertEqual(ProjectCanvas.sdNTSC.geometry, .standardDefinition)
    }

    func testTheCanvasRoundTripsThroughPreferences() throws {
        var preferences = Preferences()
        XCTAssertEqual(preferences.projectCanvas, .sdNTSC, "SD NTSC is the default")
        preferences.projectCanvas = .vertical
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data).projectCanvas, .vertical)
    }

    func testAnUnavailableOrUnknownCanvasReadsAsSD() throws {
        for stored in ["hd", "somethingFromTheFuture"] {
            let json = Data(#"{"projectCanvas":"\#(stored)","setupCompleted":true}"#.utf8)
            let preferences = try JSONDecoder().decode(Preferences.self, from: json)
            XCTAssertEqual(preferences.projectCanvas, .sdNTSC, stored)
            XCTAssertTrue(preferences.setupCompleted, "the rest of the file still loads")
        }
    }

    func testTheEnvironmentOverridesOnlyWithAnAvailableCanvas() {
        XCTAssertEqual(ProjectCanvas.atLaunch(stored: .sdNTSC, environment: [:]), .sdNTSC)
        XCTAssertEqual(ProjectCanvas.atLaunch(stored: .sdNTSC, environment: ["VIDEOBOY_CANVAS": "vertical"]), .vertical)
        XCTAssertEqual(ProjectCanvas.atLaunch(stored: .vertical, environment: ["VIDEOBOY_CANVAS": "hd"]), .vertical)
    }

    func testALandscapeClipIsLetterboxedOnTheVerticalCanvas() {
        let vertical = ProjectCanvas.vertical.geometry
        let placed = vertical.placement(sourceAspect: 16.0 / 9.0, framing: .fit)
        XCTAssertEqual(placed.size.x, 1, accuracy: 1e-5, "full width")
        // 16:9 inside 9:16: (9/16) / (16/9) of the height.
        XCTAssertEqual(placed.size.y, Float((9.0 / 16.0) / (16.0 / 9.0)), accuracy: 1e-4)
        XCTAssertEqual(placed.origin.y, (1 - placed.size.y) / 2, accuracy: 1e-5, "centred")
    }

    func testAVerticalClipFillsTheVerticalCanvasAtFullSize() {
        let vertical = ProjectCanvas.vertical.geometry
        let size = vertical.decodeSize(sourceAspect: 9.0 / 16.0, nativeSize: (1080, 1920))
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
        let placed = vertical.placement(sourceAspect: 9.0 / 16.0, framing: .fit)
        XCTAssertEqual(placed.size.x, 1, accuracy: 1e-5)
        XCTAssertEqual(placed.size.y, 1, accuracy: 1e-5)
    }
}
