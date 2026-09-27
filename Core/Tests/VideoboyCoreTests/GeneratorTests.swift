//
//  GeneratorTests.swift — the synthetic source set (SPEC 6A).
//
//  Purpose : Each generator is checked for the property that makes it that
//            generator — a checkerboard must alternate, a gradient must run one way,
//            noise must not repeat — rather than just "it rendered something".
//  Inputs   : none; generators take no texture.
//  Outputs  : assertions, plus a contact sheet under selfqa/out/phase-4/generators/.
//  Connects : GeneratorSourceNode, MetalContext.generatorPipeline, LFO.
//

import XCTest
import Metal
@testable import VideoboyCore

final class GeneratorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Renders one generator and reads it back.
    private func generate(
        _ kind: GeneratorKind,
        scale: Double = 0.5,
        phase: Double = 0,
        amount: Double = 0.5,
        colorA: GeneratorColor = .black,
        colorB: GeneratorColor = .legalWhite,
        width: Int = 160,
        height: Int = 120
    ) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let node = GeneratorSourceNode(identifier: "test.generator", context: metal)
        node.generator = kind
        node.scale = scale
        node.phase = phase
        node.amount = amount
        node.colorA = colorA
        node.colorB = colorB

        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: width, height: height)
        guard let output = node.render(inputs: [], context: context),
              let image = renderer.readback(output) else {
            throw XCTSkip("the generator produced nothing")
        }
        return image
    }

    func testSolidIsFlatAndTakesItsColour() throws {
        let red = GeneratorColor(red: 0.8, green: 0.1, blue: 0.1)
        let image = try generate(.solid, colorA: red, colorB: red)
        let mean = FrameAssertions.meanColor(image)
        XCTAssertEqual(mean.r, 204, accuracy: 3)
        XCTAssertEqual(mean.g, 26, accuracy: 3)
        // Flat means no variance at all.
        XCTAssertLessThan(FrameAssertions.luminanceVariance(image), 1.0)
    }

    func testLinearGradientRunsAcrossTheFrame() throws {
        // Phase 0 points the gradient along +x, so the left must be darker.
        let image = try generate(.linearGradient, phase: 0, colorA: .black, colorB: .white)
        let left = FrameAssertions.meanColor(image, region: (x: 0, y: 40, width: 20, height: 40))
        let right = FrameAssertions.meanColor(image, region: (x: 140, y: 40, width: 20, height: 40))
        XCTAssertGreaterThan(right.r, left.r + 100, "the gradient must run left to right at phase 0")
    }

    func testRadialGradientIsBrightestAtTheEdge() throws {
        let image = try generate(.radialGradient, scale: 0.5, colorA: .black, colorB: .white)
        let centre = FrameAssertions.meanColor(image, region: (x: 70, y: 50, width: 20, height: 20))
        let corner = FrameAssertions.meanColor(image, region: (x: 0, y: 0, width: 20, height: 20))
        XCTAssertGreaterThan(corner.r, centre.r, "distance from centre must increase the value")
    }

    func testCheckerboardAlternates() throws {
        let image = try generate(.checkerboard, scale: 0.0, colorA: .black, colorB: .white)
        // Both extremes must be present — a checkerboard that came out flat would
        // still pass a "did it render" check.
        var sawDark = false
        var sawLight = false
        for y in stride(from: 0, to: 120, by: 4) {
            for x in stride(from: 0, to: 160, by: 4) {
                let luma = Double(image.pixel(x: x, y: y).r)
                if luma < 40 { sawDark = true }
                if luma > 200 { sawLight = true }
            }
        }
        XCTAssertTrue(sawDark && sawLight, "a checkerboard must contain both colours")
    }

    func testCheckerboardPhaseShiftsIt() throws {
        let still = try generate(.checkerboard, scale: 0.2, phase: 0.0)
        let shifted = try generate(.checkerboard, scale: 0.2, phase: 0.5)
        // This is what makes "flip the checkerboard every 1/4" work: an LFO on phase.
        XCTAssertGreaterThan(
            FrameAssertions.differingPixelFraction(still, shifted), 0.2,
            "phase must move the checkerboard")
    }

    func testGridHasThinLinesOnAFlatField() throws {
        let image = try generate(.grid, scale: 0.5, amount: 0.05, colorA: .black, colorB: .white)
        let mean = FrameAssertions.meanColor(image)
        // Thin lines: mostly background, so the mean must sit near the dark colour.
        XCTAssertLessThan(mean.r, 120, "a thin grid must be mostly background")
        XCTAssertGreaterThan(FrameAssertions.horizontalDetail(image), 3.0, "it must have edges")
    }

    func testWhiteNoiseIsNoisyAndReseedsWithPhase() throws {
        let first = try generate(.whiteNoise, phase: 0.0)
        let second = try generate(.whiteNoise, phase: 0.5)
        XCTAssertGreaterThan(FrameAssertions.luminanceVariance(first), 1000,
                             "white noise must have high variance")
        XCTAssertGreaterThan(
            FrameAssertions.differingPixelFraction(first, second), 0.5,
            "changing phase must reseed the noise, so it can crackle on a beat")
    }

    func testNoiseFieldIsSmootherThanWhiteNoise() throws {
        let white = try generate(.whiteNoise)
        let smooth = try generate(.noiseField, scale: 0.3)
        XCTAssertLessThan(
            FrameAssertions.horizontalDetail(smooth),
            FrameAssertions.horizontalDetail(white),
            "a smooth noise field must carry less high-frequency detail than white noise")
    }

    func testPlasmaOctavesAddDetail() throws {
        let fewOctaves = try generate(.plasma, scale: 0.3, amount: 0.0)
        let manyOctaves = try generate(.plasma, scale: 0.3, amount: 1.0)
        XCTAssertGreaterThan(
            FrameAssertions.horizontalDetail(manyOctaves),
            FrameAssertions.horizontalDetail(fewOctaves),
            "more octaves must add fine detail")
    }

    func testEveryGeneratorProducesAValidPicture() throws {
        for kind in GeneratorKind.allCases {
            let image = try generate(kind, scale: 0.4, phase: 0.2, amount: 0.6)
            XCTAssertEqual(image.width, 160, "\(kind.displayName) came out the wrong size")
            XCTAssertEqual(image.height, 120)
            XCTAssertFalse(kind.displayName.isEmpty)
            // Only the solid is legitimately flat; everything else must have content.
            if kind != .solid {
                XCTAssertGreaterThan(
                    FrameAssertions.luminanceVariance(image), 1.0,
                    "\(kind.displayName) produced a flat frame")
            }
        }
    }

    func testOutOfGamutWarning() {
        // SPEC 6A asks for an out-of-gamut warning: full-scale white is illegal in a
        // broadcast signal and blooms on a CRT.
        XCTAssertTrue(GeneratorColor.white.isOutOfGamut)
        XCTAssertTrue(GeneratorColor.black.isOutOfGamut)
        XCTAssertFalse(GeneratorColor.legalWhite.isOutOfGamut)

        let node = GeneratorSourceNode(identifier: "test", context: nil)
        node.colorA = .legalWhite
        node.colorB = .legalWhite
        XCTAssertFalse(node.hasOutOfGamutColor)
        node.colorB = .white
        XCTAssertTrue(node.hasOutOfGamutColor)
    }

    func testGeneratorKindSelectionRoundTrips() {
        XCTAssertEqual(GeneratorKind.from(normalised: 0), .solid)
        XCTAssertEqual(GeneratorKind.from(normalised: 1), GeneratorKind.allCases.last)
        // Raw values are the shader contract.
        XCTAssertEqual(GeneratorKind.solid.rawValue, 0)
        XCTAssertEqual(GeneratorKind.scanlines.rawValue, 11)
        XCTAssertEqual(GeneratorKind.nowPlaying.rawValue, 12)
        XCTAssertEqual(GeneratorKind.allCases.count, 13)
    }

    /// An LFO driving a generator's phase is the headline use from SPEC 6A.
    func testLFODrivesAGeneratorParameter() throws {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let registry = ParamRegistry()
        let node = GeneratorSourceNode(identifier: "gen", context: MetalContext.shared)
        node.generator = .checkerboard
        node.scale = 0.2
        registry.register(slot: "gen", parameters: node.parameters)

        let bank = LFOBank(transport: transport)
        // Square wave on 1/4: the checkerboard flips on every beat.
        bank.assign(LFOBank.Assignment(
            lfo: LFO(shape: .square, rate: .subdivision(.quarter), depth: 0.5),
            slot: "gen", code: .positionX
        ))

        // First half of the beat: the square is low.
        bank.update(atHostTime: 0.1, into: registry)
        node.applyParameters(from: registry)
        let firstHalf = node.phase

        // Second half: the square is high, so the phase has jumped.
        bank.update(atHostTime: 0.4, into: registry)
        node.applyParameters(from: registry)
        let secondHalf = node.phase

        XCTAssertNotEqual(firstHalf, secondHalf, accuracy: 1e-9,
                          "a square LFO on phase must flip the pattern within the beat")
    }

    func testWriteGeneratorEvidence() throws {
        let check = SelfQACheck(name: "phase-4/generators")
        check.note("the SPEC 6A base set, each at 720x480")
        for kind in GeneratorKind.allCases {
            let image = try generate(
                kind, scale: 0.35, phase: 0.15, amount: 0.6,
                width: StandardDefinition.width, height: StandardDefinition.height
            )
            try check.writeImage(
                image,
                named: String(format: "%02d-%@.png", kind.rawValue,
                              kind.displayName.lowercased()
                                .replacingOccurrences(of: " / ", with: "-")
                                .replacingOccurrences(of: " ", with: "-"))
            )
            check.record(FrameAssertions.hasDimensions(
                image, width: StandardDefinition.width, height: StandardDefinition.height))
        }
        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-4/generators/result.txt")
    }
}
