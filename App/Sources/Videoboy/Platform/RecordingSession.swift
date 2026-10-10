//
//  RecordingSession.swift — one take, across every armed feed.
//
//  Purpose : SPEC 15 asks for discrete recording: PROGRAM plus any of A/B/C/D, each
//            to its own file, all starting and stopping together so they line up on a
//            timeline afterwards. This owns the recorders and the naming, so nothing
//            else has to know how many files a take is.
//  Inputs   : which feeds are armed, a codec, a folder; then a texture per feed per
//            frame, with the frame's presentation time; and the clock's audio,
//            through `audioSink`.
//  Outputs : one .mov per armed feed, in a folder named for the take, each with the
//            same sound track when the beat was coming from audio.
//  Connects: FrameRecorder, TakeAudio, RecordedFrameClock (Core), ShellController
//            (which arms, pushes frames, and attaches the Engine's audio feed).
//  Extend  : a new feed is a new entry in the armed set — the naming and the
//            start/stop are already per-feed.
//
//  Why one folder per take rather than one folder of everything: five files that
//  belong together are a take, and finding them a week later should not depend on
//  having read the timestamps carefully.
//

import Foundation
import Metal
import VideoboyCore

/// One recording, across every armed feed.
final class RecordingSession {

    /// Where this take's files are going.
    let folder: URL
    /// When it started, for the elapsed readout.
    let startedAt = Date()

    private let recorders: [String: FrameRecorder]
    private let renderer: OffscreenRenderer?
    /// Where each frame goes on the timeline. Main thread.
    private var frameClock = RecordedFrameClock()
    /// The take's sound, written into every recorder.
    private let audio: TakeAudio

    /// Whether the take ended up with any sound. Valid once `finish` calls back.
    private(set) var hadAudio = false

    /// Feeds that failed to open, reported once rather than every frame.
    let failedFeeds: [String]

    /// Opens a recorder per armed feed.
    ///
    /// - Parameters:
    ///   - feeds: label to graph slot, e.g. "P" to the output slot.
    ///   - directory: where the take's folder is made.
    ///   - framesAreRealTime: false only for the self-QA check, which renders as fast
    ///     as it can; it stops the audio filling silence against the wall clock.
    init(
        feeds: [String: String],
        codec: FrameRecorder.Codec,
        directory: URL,
        metal: MetalContext?,
        framesAreRealTime: Bool = true
    ) throws {
        let stamp = Self.timestampFormatter.string(from: startedAt)
        folder = directory.appendingPathComponent("Videoboy \(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        renderer = metal.flatMap { OffscreenRenderer(context: $0) }

        var opened: [String: FrameRecorder] = [:]
        var failed: [String] = []
        for (label, _) in feeds.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent("\(label).mov")
            do {
                opened[label] = try FrameRecorder(url: url, codec: codec)
            } catch {
                // One feed failing must not take the take down with it: the others
                // are still worth having, and stopping everything because channel C
                // could not open would be the worse outcome mid-set.
                failed.append(label)
                Log.error(.app, "could not record \(label): \(error.localizedDescription)")
            }
        }

        guard !opened.isEmpty else {
            throw NSError(
                domain: "Videoboy", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no feed could be opened for recording"])
        }
        recorders = opened
        failedFeeds = failed
        audio = TakeAudio(
            recorders: opened.keys.sorted().compactMap { opened[$0] },
            keepsUpWhileQuiet: framesAreRealTime)
    }

    /// Where the clock's audio goes while this take records. Attach it to the
    /// Engine's `recordAudioFeed`; it holds the take's audio, not the session.
    var audioSink: AudioRecordFeed.Sink {
        let audio = self.audio
        return { samples, sampleRate, hostTime in
            audio.receive(samples, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    /// The labels actually recording.
    var activeFeeds: [String] { recorders.keys.sorted() }

    /// Total frames written across every feed.
    var totalFrames: Int { recorders.values.reduce(0) { $0 + Int($1.frameCount) } }

    /// The take's length in frames, counting any held across a stall.
    var frameCount: Int { frameClock.frameCount }

    /// Writes this frame to every recorder, given a way to find each feed's texture.
    ///
    /// - Parameter presentationTime: when the frame is shown (host clock) — the
    ///   Engine's `framePresentationTime`. It is what the sound is lined up against.
    func write(presentationTime: Double, textureFor: (String) -> MTLTexture?) {
        guard let renderer,
              let index = frameClock.index(forPresentationTime: presentationTime) else { return }
        if index == 0 { audio.start(at: presentationTime) }
        for (label, recorder) in recorders {
            guard let texture = textureFor(label),
                  let image = renderer.readback(texture) else { continue }
            recorder.write(image, frameIndex: index)
        }
    }

    /// Closes every file, calling back on the main queue once they are all safe to
    /// open. Detach `audioSink` from the feed first.
    func finish(completion: @escaping ([URL]) -> Void) {
        let recorders = Array(self.recorders.values)
        // The audio is drained first, and the files closed from its queue, so no
        // audio append can land on a writer that is already finishing.
        audio.finish { [self] hadAudio in
            let group = DispatchGroup()
            var written: [URL] = []
            let lock = NSLock()

            for recorder in recorders {
                group.enter()
                recorder.finish { url in
                    if let url {
                        lock.lock()
                        written.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.hadAudio = hadAudio
                completion(written.sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
        }
    }

    /// Where recordings go when no save location has been set.
    ///
    /// ~/Movies/Videoboy, because that is where macOS puts video and someone who has
    /// not chosen a folder should still be able to find what they recorded.
    static func defaultDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Videoboy", isDirectory: true)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Sortable, and legal in a filename on every filesystem this will meet.
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
