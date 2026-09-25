//
//  ClipDecodersTests.swift — every sample container reports a length.
//
//  The library's Duration column comes from here. DV is measured from its size and
//  must agree with what the DV reader counts; the MPEG and QuickTime samples have no
//  frame count in the manifest, which is exactly the imported-clip case.
//

import XCTest
@testable import VideoboyCore

final class ClipDecodersTests: XCTestCase {

    private func sample(_ name: String) throws -> URL {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no \(name)") }
        return url
    }

    func testDVLengthFromSizeMatchesTheReader() throws {
        Log.echoesToStandardError = false
        let url = try sample("bars.dv")
        let reader = try DVReader(url: url)
        let expected = Double(reader.frameCount) / reader.standard.frameRate
        XCTAssertEqual(try XCTUnwrap(ClipDecoders.duration(of: url)), expected, accuracy: 1e-9)
    }

    func testMPEGAndQuickTimeReportALength() throws {
        Log.echoesToStandardError = false
        for name in ["motion.m2v", "motion.mov"] {
            let seconds = try XCTUnwrap(ClipDecoders.duration(of: try sample(name)), name)
            XCTAssertGreaterThan(seconds, 0.5, name)
            XCTAssertLessThan(seconds, 600, name)
        }
    }

    func testAFileThatIsNotVideoHasNoLength() throws {
        Log.echoesToStandardError = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-video-\(UUID()).dv")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ClipDecoders.duration(of: url))
    }
}
