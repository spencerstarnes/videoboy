//
//  DeviceConfigTests.swift — characterization tests for config/devices.json parsing.
//
//  Written during the overnight safety-net phase. `DeviceConfig` had ZERO coverage
//  and it parses a user-supplied file, which makes it one of the few places in this
//  app where malformed real-world input is a routine expectation rather than a
//  hypothetical.
//
//  These capture CURRENT behaviour. The contract the file's own header states is
//  that a missing or malformed config is logged and degraded, never fatal, and that
//  "a partial file is not an error" — so most of what is pinned down here is the
//  degradation path rather than the happy one.
//

import XCTest
@testable import VideoboyCore

final class DeviceConfigTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-deviceconfig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    /// Writes `json` to a temp file and loads it.
    private func load(_ json: String) -> DeviceConfig {
        let url = directory.appendingPathComponent("devices.json")
        try? json.data(using: .utf8)?.write(to: url)
        return DeviceConfig.load(from: url)
    }

    // MARK: - The degradation path

    func testAMissingFileGivesAnEmptyConfigRatherThanFailing() {
        let config = DeviceConfig.load(
            from: directory.appendingPathComponent("does-not-exist.json"))
        XCTAssertNil(config.outputDisplay)
        XCTAssertNil(config.loopbackCapture)
        XCTAssertNil(config.samplesDir)
        XCTAssertNil(config.selfqaOut)
    }

    func testMalformedJSONGivesAnEmptyConfigRatherThanFailing() {
        let config = load("{ this is not json")
        XCTAssertNil(config.outputDisplay)
        XCTAssertNil(config.loopbackCapture)
    }

    func testAnEmptyFileGivesAnEmptyConfig() {
        XCTAssertNil(load("").outputDisplay)
    }

    func testAJSONArrayWhereAnObjectWasExpectedDegrades() {
        XCTAssertNil(load("[1, 2, 3]").outputDisplay)
    }

    func testAnEmptyObjectIsValidAndYieldsAllDefaults() {
        let config = load("{}")
        XCTAssertNil(config.outputDisplay)
        XCTAssertNil(config.loopbackCapture)
        XCTAssertEqual(config.requestedMode, .standardDefinition)
    }

    /// The header promises "a partial file is not an error". This is that promise.
    func testAPartialFileKeepsWhatItHasAndDefaultsTheRest() {
        let config = load(#"{ "samples_dir": "somewhere" }"#)
        XCTAssertEqual(config.samplesDir, "somewhere")
        XCTAssertNil(config.outputDisplay)
        XCTAssertEqual(config.requestedMode, .standardDefinition)
    }

    /// A wrong TYPE inside an otherwise well-formed file takes the whole config down
    /// to defaults rather than keeping the parts that were fine. Pinned as current
    /// behaviour: it is defensible (the file is one document) and it is not a crash,
    /// but it is worth knowing that one bad field costs the whole file.
    func testAWronglyTypedFieldDegradesTheWholeConfigNotJustThatField() {
        let config = load(#"{ "samples_dir": "kept?", "output_display": { "name": 42 } }"#)
        XCTAssertNil(config.outputDisplay)
        XCTAssertNil(config.samplesDir, "one bad field costs the whole document, not just itself")
    }

    // MARK: - The happy path, in the shape the example file actually uses

    func testTheExampleFileShapeParses() {
        let config = load(#"""
        {
          "_comment": "unknown keys must be ignored, the real example file has several",
          "output_display": {
            "match_by": "name",
            "name": "Display Link",
            "fallback_index": 1,
            "target_mode": { "width": 720, "height": 480, "fps": 29.97, "interlaced": true, "note": "SD" }
          },
          "loopback_capture": {
            "name": "DVC100",
            "expected_format": { "width": 720, "height": 480, "fps": 29.97, "standard": "NTSC" }
          },
          "samples_dir": "samples",
          "selfqa_out": "selfqa/out"
        }
        """#)

        XCTAssertEqual(config.outputDisplay?.name, "Display Link")
        XCTAssertEqual(config.outputDisplay?.fallbackIndex, 1)
        XCTAssertEqual(config.requestedMode.width, 720)
        XCTAssertEqual(config.requestedMode.height, 480)
        XCTAssertEqual(config.requestedMode.interlaced, true)
        XCTAssertEqual(config.loopbackCapture?.name, "DVC100")
        XCTAssertEqual(config.loopbackCapture?.expectedFormat.standard, "NTSC")
        XCTAssertEqual(config.samplesDir, "samples")
    }

    func testUnknownKeysAreIgnoredRatherThanRejected() {
        let config = load(#"{ "samples_dir": "x", "a_key_from_the_future": true }"#)
        XCTAssertEqual(config.samplesDir, "x")
    }

    // MARK: - Derived values

    func testCandidateNamesPutsThePreferredDeviceFirst() {
        let config = load(#"""
        { "loopback_capture": {
            "name": "DVC100",
            "alternate_names": ["OBS Virtual Camera", "Other"],
            "expected_format": { "width": 720, "height": 480, "fps": 29.97, "standard": "NTSC" }
        } }
        """#)
        XCTAssertEqual(
            config.loopbackCapture?.candidateNames,
            ["DVC100", "OBS Virtual Camera", "Other"])
    }

    func testCandidateNamesIsJustTheNameWhenThereAreNoAlternates() {
        let config = load(#"""
        { "loopback_capture": { "name": "Only",
            "expected_format": { "width": 720, "height": 480, "fps": 29.97, "standard": "NTSC" } } }
        """#)
        XCTAssertEqual(config.loopbackCapture?.candidateNames, ["Only"])
    }

    func testTheConnectorDefaultsToCompositeWhenUnstated() {
        let config = load(#"""
        { "loopback_capture": { "name": "D",
            "expected_format": { "width": 720, "height": 480, "fps": 29.97, "standard": "NTSC" } } }
        """#)
        XCTAssertEqual(config.loopbackCapture?.connector, "composite")
    }

    func testAStatedConnectorIsHonoured() {
        let config = load(#"""
        { "loopback_capture": { "name": "D", "input": "svideo",
            "expected_format": { "width": 720, "height": 480, "fps": 29.97, "standard": "NTSC" } } }
        """#)
        XCTAssertEqual(config.loopbackCapture?.connector, "svideo")
    }

    // MARK: - TargetMode

    func testTargetModeDescriptionIsTheShortFormUsedInMetrics() {
        XCTAssertEqual(TargetMode.standardDefinition.description, "720x480@29.97i")
        XCTAssertEqual(
            TargetMode(width: 1920, height: 1080, fps: 60, interlaced: false).description,
            "1920x1080@60.00p")
    }

    /// Nonsense geometry is carried through rather than rejected. Pinned because it
    /// is a real decision, not an oversight: this struct records what was REQUESTED,
    /// and what gets negotiated is logged separately (SPEC 3). Validating here would
    /// hide a bad config behind a silent default.
    func testAbsurdGeometryIsCarriedThroughRatherThanValidated() {
        let config = load(#"""
        { "output_display": { "name": "x", "fallback_index": 0,
            "target_mode": { "width": 0, "height": -1, "fps": 0, "interlaced": false } } }
        """#)
        XCTAssertEqual(config.requestedMode.width, 0)
        XCTAssertEqual(config.requestedMode.height, -1)
    }

    // MARK: - Boundaries

    func testAVeryLongDeviceNameIsAcceptedWhole() {
        let long = String(repeating: "D", count: 10_000)
        let config = load(#"{ "loopback_capture": { "name": "\#(long)", "expected_format": { "width": 1, "height": 1, "fps": 1, "standard": "NTSC" } } }"#)
        XCTAssertEqual(config.loopbackCapture?.name.count, 10_000)
    }

    func testAnEmptyDeviceNameIsAcceptedRatherThanTreatedAsAbsent() {
        let config = load(#"{ "loopback_capture": { "name": "", "expected_format": { "width": 1, "height": 1, "fps": 1, "standard": "NTSC" } } }"#)
        XCTAssertEqual(config.loopbackCapture?.name, "")
        XCTAssertEqual(config.loopbackCapture?.candidateNames, [""])
    }

    func testLoadingIsRepeatableAndDoesNotMutateTheFile() {
        let json = #"{ "samples_dir": "stable" }"#
        XCTAssertEqual(load(json).samplesDir, "stable")
        XCTAssertEqual(load(json).samplesDir, "stable")
        XCTAssertEqual(load(json).samplesDir, "stable")
    }
}
