//
//  ISFAudioFeed.swift — the live audio that ISF `audio` and `audioFFT` inputs see.
//
//  Purpose : ISF shaders read sound as images: `audio` is the waveform (one row of
//            samples, 0.5 is silence), `audioFFT` the spectrum (one row of bins, 0 is
//            nothing). This holds the newest analysed window and turns it into those
//            images at whatever width a shader asks for (its input's MAX).
//  Inputs  : `AudioFrame`s, from whichever capture is running, on its analysis queue.
//  Outputs : `ImageBuffer`s, one row high, on request (the render thread).
//  Connects: AudioAnalyzer (fills the frames), Engine (routes frames here), ISFNode
//            (uploads the images, only when `version` moved).
//  Extend  : stereo would be a second row per image. The analyser is mono today, and
//            a one-row image reads the same at any `y`, so shaders that sample
//            channel 0 or 0.5 all see the sound.
//
//  THREADS. Written on the audio analysis queue, read on the render thread: one lock,
//  held only to copy two small arrays. Nothing here touches Metal.
//

import Foundation

/// The newest audio window, as ISF images.
public final class ISFAudioFeed: @unchecked Sendable {

    /// The one the app's capture writes to and every ISF node reads.
    public static let shared = ISFAudioFeed()

    /// Default widths when an input gives no MAX.
    public static let defaultWaveformWidth = 512
    public static let defaultSpectrumWidth = 256

    private let lock = NSLock()
    private var waveform: [Float] = []
    private var spectrum: [Float] = []
    private var stamp = 0

    public init() {}

    /// Bumped with every new window, so a reader re-uploads only when it moved.
    public var version: Int {
        lock.lock(); defer { lock.unlock() }
        return stamp
    }

    /// Takes a new analysed window. Any thread.
    public func update(with frame: AudioFrame) {
        lock.lock()
        waveform = frame.waveform
        spectrum = frame.spectrum
        stamp += 1
        lock.unlock()
    }

    /// Back to silence, when capture stops — a frozen last window would read as a
    /// stuck sound.
    public func silence() {
        lock.lock()
        waveform = []
        spectrum = []
        stamp += 1
        lock.unlock()
    }

    /// The waveform as a one-row image `width` wide: 0.5 grey is silence.
    public func waveformImage(width: Int) -> ImageBuffer {
        lock.lock(); let samples = waveform; lock.unlock()
        return ISFAudioFeed.row(width: width) { position in
            guard !samples.isEmpty else { return 0.5 }
            let index = min(samples.count - 1, position * samples.count / max(width, 1))
            return samples[index] * 0.5 + 0.5
        }
    }

    /// The spectrum as a one-row image `width` wide, low frequencies on the left.
    /// Each pixel is the loudest bin it covers, so a narrow image keeps its peaks.
    public func spectrumImage(width: Int) -> ImageBuffer {
        lock.lock(); let bins = spectrum; lock.unlock()
        return ISFAudioFeed.row(width: width) { position in
            guard !bins.isEmpty else { return 0 }
            let start = position * bins.count / max(width, 1)
            let end = max(start + 1, (position + 1) * bins.count / max(width, 1))
            return bins[start..<min(end, bins.count)].max() ?? 0
        }
    }

    private static func row(width: Int, value: (Int) -> Float) -> ImageBuffer {
        let width = max(width, 1)
        var pixels = [UInt8](repeating: 255, count: width * ImageBuffer.bytesPerPixel)
        for x in 0..<width {
            let level = UInt8(min(max(value(x), 0), 1) * 255)
            pixels[x * 4] = level
            pixels[x * 4 + 1] = level
            pixels[x * 4 + 2] = level
        }
        return ImageBuffer(width: width, height: 1, pixels: pixels)
    }
}
