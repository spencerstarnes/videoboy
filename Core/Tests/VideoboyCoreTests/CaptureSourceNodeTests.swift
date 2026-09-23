//
//  CaptureSourceNodeTests.swift — a configured source really reaches a channel.
//
//  Same discipline commit `96b4244` used for the Transform position faders: a node
//  rendering correctly proves nothing about whether anything downstream can actually
//  reach it. Here the equivalent bug would be a channel pointed at a capture node
//  that never delivers what was submitted to it, or a `CaptureSourceNode` that
//  reports itself live before it has actually received a frame.
//

import XCTest
@testable import VideoboyCore

final class CaptureSourceNodeTests: XCTestCase {

    func testIsLiveOnlyAfterAFrameArrives() {
        let node = CaptureSourceNode(identifier: "source.capture.test", context: nil)
        XCTAssertFalse(node.isLive, "a configured source with no session running is not live")

        let frame = ImageBuffer(width: 4, height: 4, r: 128, g: 128, b: 128)
        node.submit(frame: frame, deviceName: "Test Camera")
        XCTAssertTrue(node.isLive, "isLive must flip true the moment a real frame is submitted")
    }

    func testDeviceNameIsReportedFromTheActualFrameNotTheRequest() {
        let node = CaptureSourceNode(identifier: "source.capture.test", context: nil)
        node.setPreferredDeviceName("Requested Camera")
        XCTAssertNil(
            node.deviceName,
            "deviceName is a FACT (what actually delivered a frame), not the request — "
                + "conflating the two is how a panel ends up claiming a camera is live "
                + "because somebody merely picked it")

        let frame = ImageBuffer(width: 4, height: 4, r: 0, g: 0, b: 0)
        node.submit(frame: frame, deviceName: "Actual Camera")
        XCTAssertEqual(node.deviceName, "Actual Camera")
    }

    func testReceivedFrameCountTracksEverySubmission() {
        let node = CaptureSourceNode(identifier: "source.capture.test", context: nil)
        let frame = ImageBuffer(width: 2, height: 2, r: 255, g: 255, b: 255)
        for _ in 0..<5 { node.submit(frame: frame, deviceName: "Camera") }
        XCTAssertEqual(node.receivedFrameCount, 5)
    }

    /// Renders without a Metal context (this test's own headless CI reality — see
    /// `context: nil` above) must not crash, the same guarantee every other node in
    /// this graph gives when hardware is absent.
    func testRenderIsSafeWithNoMetalContext() {
        let node = CaptureSourceNode(identifier: "source.capture.test", context: nil)
        node.submit(frame: ImageBuffer(width: 4, height: 4, r: 1, g: 2, b: 3), deviceName: "Camera")
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        XCTAssertNil(node.render(inputs: [], context: context))
    }
}
