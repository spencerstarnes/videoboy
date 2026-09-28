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

    /// Same shape, same reasoning as `testDestinationsRoundTrip` — a configured
    /// source is what replaced the single `captureDeviceName: String?` this session,
    /// so it needs the same proof: every field survives a save and a reload, for
    /// every kind, including the ones that carry `windowOwnerName`.
    func testConfiguredSourcesRoundTrip() {
        let store = PreferenceStore(fileURL: fileURL)
        store.preferences.configuredSources = [
            ConfiguredSource(kind: .avfoundation, name: "DVC100", target: "DVC100"),
            ConfiguredSource(
                kind: .windowCapture, name: "OBS Studio", target: "Main Window",
                windowOwnerName: "OBS"),
            ConfiguredSource(kind: .ipCamera, name: "Porch Cam", target: "rtsp://10.0.0.4/live")
        ]
        let reopened = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.preferences.configuredSources.count, 3)
        XCTAssertEqual(reopened.preferences.configuredSources[0].kind, .avfoundation)
        XCTAssertEqual(reopened.preferences.configuredSources[1].windowOwnerName, "OBS")
        XCTAssertEqual(reopened.preferences.configuredSources[2].target, "rtsp://10.0.0.4/live")
    }

    /// A source of a kind this build no longer has (DV decks were removed) is skipped
    /// on load — the other sources and every other preference survive it.
    func testASourceOfARemovedKindIsSkippedNotFatal() throws {
        let store = PreferenceStore(fileURL: fileURL)
        store.preferences.defaultTempo = 97
        store.preferences.configuredSources = [
            ConfiguredSource(kind: .avfoundation, name: "DVC100", target: "DVC100"),
            ConfiguredSource(kind: .ipCamera, name: "GL2 deck", target: "")
        ]
        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"ipCamera\""))
        try saved.replacingOccurrences(of: "\"ipCamera\"", with: "\"dvDeck\"")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let reopened = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(reopened.preferences.configuredSources.map(\.name), ["DVC100"])
        XCTAssertEqual(reopened.preferences.defaultTempo, 97)
    }

    /// A preferences file saved before this type existed has no `configuredSources`
    /// key at all — must load to the empty list, not fail the whole file.
    func testAFileWithNoConfiguredSourcesKeyLoadsEmpty() throws {
        let old = """
        { "defaultTempo": 90 }
        """
        try old.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertTrue(store.preferences.configuredSources.isEmpty)
    }

    /// Same "one bad element must not sink the list" rule `destinations` already
    /// proves, applied to sources — a kind this build has retired should not cost
    /// someone every camera they configured.
    func testAnUnknownSourceKindIsSkippedRatherThanLosingTheList() throws {
        let withRetiredKind = """
        {
          "configuredSources": [
            {"id": "a", "kind": "avfoundation", "name": "Webcam", "target": "Webcam"},
            {"id": "b", "kind": "firewireDeck", "name": "Old Deck", "target": ""},
            {"id": "c", "kind": "ipCamera", "name": "Cam", "target": "rtsp://x"}
          ]
        }
        """
        try withRetiredKind.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(store.preferences.configuredSources.map(\.id), ["a", "c"])
    }
}

final class ConfiguredSourceKindTests: XCTestCase {

    func testOnlyAVFoundationAndWindowCaptureAreImplemented() {
        XCTAssertTrue(ConfiguredSourceKind.avfoundation.isImplemented)
        XCTAssertTrue(ConfiguredSourceKind.windowCapture.isImplemented)
        XCTAssertFalse(ConfiguredSourceKind.ipCamera.isImplemented)
    }

    /// Every badge must be one the app's existing kind-name lookup already knows
    /// (`LibraryItem.kind`), or a Sources tile would show a raw three-letter code
    /// where every other tab's tile shows a real name.
    func testEveryBadgeIsUnique() {
        let badges = ConfiguredSourceKind.allCases.map(\.badge)
        XCTAssertEqual(badges.count, Set(badges).count, "two source kinds share a badge")
    }
}

extension PreferenceTests {
    /// A destination of a kind this build no longer has must not take its neighbours
    /// with it. Capture cards were offered as outputs once; a card is an input.
    func testAnUnknownDestinationKindIsSkippedRatherThanLosingTheList() throws {
        let withRetiredKind = """
        {
          "destinations": [
            {"id": "a", "kind": "obs", "name": "OBS", "target": "9000"},
            {"id": "b", "kind": "captureCard", "name": "Black Magic", "target": "card"},
            {"id": "c", "kind": "feedbackSend", "name": "Feedback", "target": "ONE"}
          ]
        }
        """
        try withRetiredKind.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = PreferenceStore(fileURL: fileURL)
        XCTAssertEqual(
            store.preferences.destinations.count, 2,
            "the two live destinations should survive the retired one")
        XCTAssertEqual(store.preferences.destinations.map(\.id), ["a", "c"])
    }

    func testCaptureCardIsNoLongerOfferedAsADestination() {
        XCTAssertFalse(
            OutputDestination.Kind.allCases.contains { $0.rawValue == "captureCard" },
            "a capture card is an input; offering it as an output was a mistake")
    }
}
