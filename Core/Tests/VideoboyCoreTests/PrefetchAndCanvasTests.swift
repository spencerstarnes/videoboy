//
//  PrefetchAndCanvasTests.swift — the 0.4.6 decode path: canvas fitting and decoding
//  ahead of the playhead.
//
//  Purpose : The two things that moved decoding out of the render tick must be exact:
//            the geometry that decides how big to decode and where a picture sits,
//            and the prefetcher that hands the tick the SAME picture a direct decode
//            would have — decoded off the main thread, and ready at a loop wrap.
//  Inputs  : samples/ (bars.dv, motion.mov), a mock decoder.
//  Connects: CanvasGeometry, ClipPrefetcher, ClipSourceNode.
//

import XCTest
@testable import VideoboyCore

final class CanvasGeometryTests: XCTestCase {

    private let sd = CanvasGeometry.standardDefinition

    func testStandardRastersAreShownFourByThree() {
        XCTAssertEqual(CanvasGeometry.displayAspect(width: 720, height: 480), 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(CanvasGeometry.displayAspect(width: 720, height: 576), 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(CanvasGeometry.displayAspect(width: 1920, height: 1080), 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(CanvasGeometry.displayAspect(width: 1080, height: 1080), 1, accuracy: 1e-9)
    }

    func testAnHDClipIsDecodedJustLargeEnoughToFillSD() {
        let size = sd.decodeSize(sourceAspect: 16.0 / 9.0, nativeSize: (1920, 1080))
        XCTAssertEqual(size.height, 480, "fills the canvas height")
        XCTAssertEqual(size.width, 854, "keeps 16:9")
    }

    func testAPortraitClipDecodesTallEnoughToFillTheWidth() {
        let size = sd.decodeSize(sourceAspect: 9.0 / 16.0, nativeSize: (1080, 1920))
        // Filling a 4:3 canvas with 9:16 needs the picture 4:3 ÷ 9:16 ≈ 2.37 canvas-heights tall.
        XCTAssertEqual(size.height, 1138)
        XCTAssertEqual(size.width, 640)
    }

    func testNothingIsEverDecodedLargerThanTheFile() {
        let size = sd.decodeSize(sourceAspect: 16.0 / 9.0, nativeSize: (640, 360))
        XCTAssertEqual(size.height, 360)
        XCTAssertEqual(size.width, 640)
    }

    func testFitLetterboxesAWideSourceAndFillCropsIt() {
        let fit = sd.placement(sourceAspect: 16.0 / 9.0, framing: .fit)
        XCTAssertEqual(fit.size.x, 1, accuracy: 1e-6)
        XCTAssertEqual(fit.size.y, 0.75, accuracy: 1e-6, "16:9 in 4:3 is three quarters high")
        XCTAssertEqual(fit.origin.y, 0.125, accuracy: 1e-6, "centred: equal bars")

        let fill = sd.placement(sourceAspect: 16.0 / 9.0, framing: .fill)
        XCTAssertEqual(fill.size.y, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(fill.size.x, 1, "overflows the sides, which are cropped")

        let stretch = sd.placement(sourceAspect: 16.0 / 9.0, framing: .stretch)
        XCTAssertEqual(stretch.size.x, 1, accuracy: 1e-6)
        XCTAssertEqual(stretch.size.y, 1, accuracy: 1e-6)
    }
}

/// A decoder whose every frame says which index it is, and which records the thread
/// each decode ran on.
private final class CountingDecoder: ClipDecoding {
    let frameCount: Int
    let frameRate = StandardDefinition.frameRate
    var dataEffectFamily: DataEffectFamily { .none }
    private let lock = NSLock()
    private(set) var decodes: [(index: Int, onMain: Bool)] = []

    init(frameCount: Int) { self.frameCount = frameCount }

    func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer? {
        lock.lock(); decodes.append((index, Thread.isMainThread)); lock.unlock()
        let value = UInt8(index % 256)
        return ImageBuffer(width: 4, height: 4, r: value, g: UInt8(corruption.seed % 256), b: 0)
    }

    var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return decodes.count }
}

final class ClipPrefetcherTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { usleep(1000) }
    }

    func testPrefetchedFramesAreDecodedOffTheMainThreadAndServedAsHits() {
        let decoder = CountingDecoder(frameCount: 100)
        let prefetcher = ClipPrefetcher(decoder: decoder, label: "test")
        prefetcher.prefetch([1, 2, 3], damage: .inert)
        waitUntil { prefetcher.statistics.prefetched == 3 }

        XCTAssertEqual(prefetcher.statistics.prefetched, 3)
        XCTAssertFalse(decoder.decodes.contains { $0.onMain }, "no decode ran on the main thread")

        let before = decoder.decodeCount
        let image = prefetcher.image(at: 2, damage: .inert)
        XCTAssertEqual(image?.pixels.first, 2, "the right frame")
        XCTAssertEqual(decoder.decodeCount, before, "a hit does not decode again")
        XCTAssertEqual(prefetcher.statistics.hits, 1)
    }

    func testAMissDecodesTheFrameItWasAskedFor() {
        let decoder = CountingDecoder(frameCount: 100)
        let prefetcher = ClipPrefetcher(decoder: decoder, label: "test")
        let image = prefetcher.image(at: 42, damage: .inert)
        XCTAssertEqual(image?.pixels.first, 42)
        XCTAssertEqual(prefetcher.statistics.misses, 1)
    }

    func testChangedDamageIsNeverServedFromFramesDecodedWithTheOldDamage() {
        let decoder = CountingDecoder(frameCount: 100)
        let prefetcher = ClipPrefetcher(decoder: decoder, label: "test")
        prefetcher.prefetch([5], damage: .inert)
        waitUntil { prefetcher.statistics.prefetched == 1 }

        var reseeded = CorruptionSettings.inert
        reseeded.seed = 7
        let image = prefetcher.image(at: 5, damage: reseeded)
        XCTAssertEqual(image?.pixels[1], 7, "decoded with the new damage")
        XCTAssertEqual(prefetcher.statistics.misses, 1)
    }

    func testTheRingStaysBounded() {
        let decoder = CountingDecoder(frameCount: 1000)
        let prefetcher = ClipPrefetcher(decoder: decoder, label: "test")
        for start in stride(from: 0, to: 200, by: 5) {
            prefetcher.prefetch(Array(start..<(start + 5)), damage: .inert)
            waitUntil { !decoder.decodes.isEmpty && decoder.decodes.last?.index == start + 4 }
        }
        // Everything asked for was decoded once; nothing piles up (checked indirectly:
        // an old frame is gone and has to be decoded again).
        let before = decoder.decodeCount
        _ = prefetcher.image(at: 0, damage: .inert)
        XCTAssertEqual(decoder.decodeCount, before + 1, "frame 0 was evicted long ago")
    }
}

final class ClipSourcePrefetchTests: XCTestCase {

    /// A clip played through its loop point must be served from the ring: the wrap is
    /// where the old path restarted readers on the tick.
    func testPlaybackThroughALoopWrapIsServedByThePrefetcher() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        for name in ["bars.dv", "motion.mov"] {
            let url = RepoPaths.samples.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no \(name)") }
            let node = ClipSourceNode(identifier: "test.\(name)", context: metal)
            XCTAssertTrue(node.load(url: url))
            node.isPlaying = true
            let frames = node.frameCount + 30
            for frame in 0..<frames {
                let context = RenderContext(frameIndex: frame, presentationTime: 0, musicalPosition: nil)
                XCTAssertNotNil(node.render(inputs: [], context: context))
                metal.waitForIdle()
                // Real time between ticks, as the display link gives it.
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
            }
            let stats = try XCTUnwrap(node.prefetcher?.statistics)
            // The first frame may be a miss (it can race the load's own prefetch);
            // everything after, including the wrap, must be ready.
            XCTAssertLessThanOrEqual(stats.misses, 2, "\(name): \(stats)")
            XCTAssertGreaterThan(stats.hits, frames - 3, "\(name): \(stats)")
        }
    }

    /// The prefetcher must hand the graph exactly what a direct decode produces.
    func testPrefetchedPicturesMatchADirectDecode() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no motion.dv") }
        let direct = try DVClipDecoder(url: url)
        let node = ClipSourceNode(identifier: "test.match", context: nil)
        XCTAssertTrue(node.load(url: url))
        for index in [0, 1, 17, 100] {
            let viaNode = node.renderToImage(frameIndex: index)
            let expected = direct.image(at: index, corruption: .inert)
            XCTAssertEqual(viaNode?.pixels, expected?.pixels, "frame \(index)")
        }
    }
}
