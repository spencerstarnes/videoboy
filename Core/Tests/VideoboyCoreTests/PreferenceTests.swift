//
//  PreferenceTests.swift — that settings survive, and survive being out of date.
//
//  The interesting failures here are not "does it save" but "what happens to someone
//  whose file was written by a different version". A preferences file that fails to
//  load silently resets everything, which is the kind of bug people never report and
//  simply resent.
//

import XCTest
@testable import VideoboyCore

final class PreferenceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("preferences.json") }

    func testSettingsSurviveARestart() {
        let store = PreferenceStore(fileURL: fileURL)
        store.preferences.autoSave = .everyFifteenMinutes
        store.preferences.defaultTempo = 174
        store.preferences.saveLocation = URL(fileURLWithPath: "/tmp/sets", isDirectory: true)

        let reopened = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.preferences.autoSave, .everyFifteenMinutes)
        XCTAssertEqual(reopened.preferences.defaultTempo, 174)
        XCTAssertEqual(reopened.preferences.saveLocation?.path, "/tmp/sets")
    }

    func testSuppressedRemindersStaySuppressed() {
        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertTrue(store.shouldRemind(.saveOnQuit))
        store.suppressReminder(.saveOnQuit)
        XCTAssertFalse(store.shouldRemind(.saveOnQuit))

        let reopened = PreferenceStore(fileURL: fileURL)
        XCTAssertFalse(
            reopened.shouldRemind(.saveOnQuit),
            "a dismissed reminder must stay dismissed across launches — that is the whole feature")
        XCTAssertTrue(
            reopened.shouldRemind(.setSaveLocation),
            "dismissing one reminder must not dismiss the others")
    }

    func testResettingRemindersBringsThemAllBack() {
        let store = PreferenceStore(fileURL: fileURL)
        for kind in ReminderKind.allCases { store.suppressReminder(kind) }
        store.resetReminders()
        for kind in ReminderKind.allCases {
            XCTAssertTrue(store.shouldRemind(kind), "\(kind.rawValue) should be back")
        }
    }

    /// A file from an older version is missing keys that exist now.
    func testAFileMissingNewerKeysLoadsWithDefaults() throws {
        let old = """
        { "defaultTempo": 90, "autoSave": "everyFiveMinutes" }
        """
        try old.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(store.preferences.defaultTempo, 90, "the keys present must be honoured")
        XCTAssertEqual(store.preferences.autoSave, .everyFiveMinutes)
        XCTAssertEqual(
            store.preferences.defaultSubdivision, "1/4",
            "a key the old file never had should take its default, not fail the load")
        XCTAssertTrue(store.preferences.destinations.isEmpty)
    }

    /// A file from a NEWER version has keys this build has never heard of.
    func testAFileWithUnknownKeysStillLoads() throws {
        let future = """
        { "defaultTempo": 128, "quantumFluxCapacitor": true, "destinations": [] }
        """
        try future.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(
            store.preferences.defaultTempo, 128,
            "an unrecognised key must not stop the rest of the file being read")
    }

    /// A corrupt file must not take someone's settings down with it on launch.
    func testACorruptFileFallsBackToDefaults() throws {
        try "{ this is not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(store.preferences.defaultTempo, 120)
        XCTAssertEqual(store.preferences.autoSave, .never)
    }

    func testDestinationsRoundTrip() {
        let store = PreferenceStore(fileURL: fileURL)
        store.preferences.destinations = [
            OutputDestination(kind: .obs, name: "OBS", target: "127.0.0.1:9000"),
            OutputDestination(kind: .feedbackSend, name: "Feedback A", target: "mix.one")
        ]
        let reopened = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.preferences.destinations.count, 2)
        XCTAssertEqual(reopened.preferences.destinations.first?.kind, .obs)
        XCTAssertEqual(reopened.preferences.destinations.last?.target, "mix.one")
    }
}
