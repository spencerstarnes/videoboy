//
//  TextureUploaderTests.swift — the reused upload path matches the original one.
//
//  Purpose : `TextureUploader` replaced `makeTexture(from:)` on every per-frame source.
//            A wrong channel map would swap red and blue on every picture in the app,
//            so this compares it pixel-for-pixel against the original, across the
//            texture reuse that is the whole point of it.
//

import XCTest
@testable import VideoboyCore

final class TextureUploaderTests: XCTestCase {

    /// A frame with distinct R, G, B and A everywhere, so any channel mix-up shows.
    private func pattern(seed: Int) -> ImageBuffer {
        var image = ImageBuffer(width: 64, height: 48)
        for y in 0..<48 {
            for x in 0..<64 {
                image.setPixel(
                    x: x, y: y,
                    r: UInt8((x * 4 + seed) & 0xff), g: UInt8((y * 5 + seed * 3) & 0xff),
                    b: UInt8((x + y + seed * 7) & 0xff), a: 255)
            }
        }
        return image
    }

    func testUploadsMatchTheOriginalPathAcrossReuse() throws {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let uploader = TextureUploader(context: metal, label: "test")
        var handedOut: [ObjectIdentifier] = []

        // Four uploads: both slots are written, then each is REUSED once.
        for seed in 0..<4 {
            let image = pattern(seed: seed)
            guard let reference = metal.makeTexture(from: image, label: "reference"),
                  let uploaded = uploader.upload(image) else {
                return XCTFail("upload \(seed) failed")
            }
            handedOut.append(ObjectIdentifier(uploaded))
            let expected = try XCTUnwrap(renderer.readback(reference))
            let actual = try XCTUnwrap(renderer.readback(uploaded))
            XCTAssertEqual(actual.pixels, expected.pixels, "upload \(seed) differs from makeTexture")
        }

        // Two textures, alternating — never a fresh allocation per frame.
        XCTAssertEqual(Set(handedOut).count, 2)
        XCTAssertEqual(handedOut[0], handedOut[2])
        XCTAssertEqual(handedOut[1], handedOut[3])
        XCTAssertNotEqual(handedOut[0], handedOut[1])
    }

    func testANewSizeAllocatesFresh() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        let uploader = TextureUploader(context: metal, label: "test")
        let small = try XCTUnwrap(uploader.upload(ImageBuffer(width: 8, height: 8, r: 1, g: 2, b: 3)))
        _ = uploader.upload(ImageBuffer(width: 8, height: 8, r: 1, g: 2, b: 3))
        let large = try XCTUnwrap(uploader.upload(ImageBuffer(width: 16, height: 8, r: 1, g: 2, b: 3)))
        XCTAssertEqual(small.width, 8)
        XCTAssertEqual(large.width, 16)
    }
}
