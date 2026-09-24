//
//  ISFAudioTests.swift — `audio` and `audioFFT` inputs carry the sound into a shader.
//

import Metal
import XCTest
@testable import VideoboyCore

final class ISFAudioTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func sine(frequency: Double, amplitude: Float, sampleRate: Double = 48_000) -> [Float] {
        (0..<AudioAnalyzer.windowSize).map {
            amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate))
        }
    }

    func testTheAnalyserHandsOverTheWaveformAndASpectrumWithItsPeakInPlace() {
        let analyzer = AudioAnalyzer(sampleRate: 48_000)
        let frame = analyzer.analyze(samples: sine(frequency: 3_000, amplitude: 0.8))
        XCTAssertEqual(frame.waveform.count, AudioAnalyzer.windowSize)
        XCTAssertEqual(frame.spectrum.count, AudioAnalyzer.windowSize / 2)
        // 3 kHz at 48 kHz over 1024 bins of 23.4 Hz: bin 64.
        let loudest = frame.spectrum.indices.max { frame.spectrum[$0] < frame.spectrum[$1] } ?? 0
        XCTAssertEqual(loudest, 64, accuracy: 1)
        XCTAssertGreaterThan(frame.spectrum[loudest], 0.8, "a loud sine sits near the top of the scale")
        XCTAssertLessThan(frame.spectrum[400], 0.2, "and far from it there is nearly nothing")
    }

    func testTheFeedDrawsSilenceAsMidGreyAndNothing() {
        let feed = ISFAudioFeed()
        XCTAssertEqual(feed.waveformImage(width: 8).pixel(x: 3, y: 0).r, 127, "0.5 is silence")
        XCTAssertEqual(feed.spectrumImage(width: 8).pixel(x: 3, y: 0).r, 0)
    }

    func testAShaderSeesTheSoundItsInputsAskFor() throws {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let feed = ISFAudioFeed()
        var frame = AudioAnalyzer(sampleRate: 48_000).analyze(samples: sine(frequency: 3_000, amplitude: 0.8))
        // A waveform that is a known ramp, so the shader's read can be checked exactly.
        frame.waveform = (0..<AudioAnalyzer.windowSize).map { Float($0) / Float(AudioAnalyzer.windowSize) }
        feed.update(with: frame)

        // Reads the waveform at x = 0.5 into red, the spectrum's loudest region into
        // green (bin 64 of 512 is 1/8 of the way along), and a quiet bin into blue.
        let source = """
            /*{ "INPUTS": [
                { "NAME": "wave", "TYPE": "audio", "MAX": 256 },
                { "NAME": "fft", "TYPE": "audioFFT", "MAX": 128 } ] }*/
            void main() {
                gl_FragColor = vec4(IMG_NORM_PIXEL(wave, vec2(0.5, 0.5)).r,
                                    IMG_PIXEL(fft, vec2(16.5, 0.5)).r,
                                    IMG_NORM_PIXEL(fft, vec2(0.9, 0.0)).r, 1.0);
            }
            """
        let program = try ISFProgram.compile(source: source, name: "audio", device: metal.device)
        let node = ISFNode(identifier: "test.audio", context: metal)
        node.audioFeed = feed
        node.install(program)
        XCTAssertTrue(node.usesAudio)
        guard let output = node.render(inputs: [], context: ISFTestSupport.context()),
              let picture = renderer.readback(output) else { throw XCTSkip("render failed") }
        let pixel = picture.pixel(x: picture.width / 2, y: picture.height / 2)
        // The ramp at the middle is 0.5, encoded as 0.5 * 0.5 + 0.5.
        XCTAssertEqual(Double(pixel.r), 0.75 * 255, accuracy: 3, "the waveform arrived")
        XCTAssertGreaterThan(pixel.g, 200, "the spectrum's peak is where 3 kHz belongs")
        XCTAssertLessThan(pixel.b, 60, "high up the spectrum it is quiet")
    }
}
