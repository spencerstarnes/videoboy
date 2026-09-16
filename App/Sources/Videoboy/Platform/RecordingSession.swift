//
//  RecordingSession.swift — one take, across every armed feed.
//
//  Purpose : SPEC 15 asks for discrete recording: PROGRAM plus any of A/B/C/D, each
//            to its own file, all starting and stopping together so they line up on a
//            timeline afterwards. This owns the recorders and the naming, so nothing
//            else has to know how many files a take is.
//  Inputs   : which feeds are armed, a codec, a folder; then a texture per feed per
//            frame.
//  Outputs : one .mov per armed feed, in a folder named for the take.
//  Connects: FrameRecorder, ShellController (which arms and pushes frames).
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

    private var recorders: [String: FrameRecorder] = [:]
    private let renderer: OffscreenRenderer?

    /// Feeds that failed to open, reported once rather than every frame.
    private(set) var failedFeeds: [String] = []

    /// Opens a recorder per armed feed.
    ///
    /// - Parameters:
    ///   - feeds: label to graph slot, e.g. "P" to the output slot.
    ///   - directory: where the take's folder is made.
    init(
        feeds: [String: String],
        codec: FrameRecorder.Codec,
        directory: URL,
        metal: MetalContext?
    ) throws {
        let stamp = Self.timestampFormatter.string(from: startedAt)
        folder = directory.appendingPathComponent("Videoboy \(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        renderer = metal.flatMap { OffscreenRenderer(context: $0) }

        for (label, _) in feeds.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent("\(label).mov")
            do {
                recorders[label] = try FrameRecorder(url: url, codec: codec)
            } catch {
                // One feed failing must not take the take down with it: the others
                // are still worth having, and stopping everything because channel C
                // could not open would be the worse outcome mid-set.
                failedFeeds.append(label)
                Log.error(.app, "could not record \(label): \(error.localizedDescription)")
            }
        }

        guard !recorders.isEmpty else {
            throw NSError(
                domain: "Videoboy", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no feed could be opened for recording"])
        }
    }

    /// The labels actually recording.
    var activeFeeds: [String] { recorders.keys.sorted() }

    /// Total frames written across every feed.
    var totalFrames: Int { recorders.values.reduce(0) { $0 + Int($1.frameCount) } }

    /// Frames written by the feed furthest along, which is the take's length.
    var frameCount: Int { recorders.values.map { Int($0.frameCount) }.max() ?? 0 }

    /// Writes this frame to every recorder, given a way to find each feed's texture.
    func write(textureFor: (String) -> MTLTexture?) {
        guard let renderer else { return }
        for (label, recorder) in recorders {
            guard let texture = textureFor(label),
                  let image = renderer.readback(texture) else { continue }
            recorder.write(image)
        }
    }

    /// Closes every file, calling back once they are all safe to open.
    func finish(completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var written: [URL] = []
        let lock = NSLock()

        for recorder in recorders.values {
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
            completion(written.sorted { $0.lastPathComponent < $1.lastPathComponent })
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
