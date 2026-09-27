//
//  NowPlayingWatcher.swift — what Apple Music (or Spotify) is playing, once a second.
//
//  Purpose : Feeds the Now Playing generator. Asks Music.app over AppleEvents for the
//            current track's title, artist, album, position and duration (and its
//            artwork when the track changes), falling back to Spotify when Music is not
//            playing, and publishes the answer to `NowPlayingHub.shared`.
//  Inputs  : AppleEvents. The first query triggers macOS's Automation prompt
//            (Info.plist: NSAppleEventsUsageDescription); if it is refused, the card
//            says so rather than showing a blank.
//  Outputs : NowPlayingHub updates.
//  Connects: ShellController (starts it when a channel is set to Now Playing),
//            GeneratorSourceNode (.nowPlaying) reads the hub.
//  Extend  : Engine DJ (StagelinQ) is another watcher publishing to the same hub —
//            docs/NOW-PLAYING-SOURCES.md.
//
//  THREADING: every AppleEvent runs on `queue` (it blocks; never on the main thread
//  or the tick). NSAppleScript is used from that one serial queue only.
//

import AppKit
import QuartzCore
import VideoboyCore

final class NowPlayingWatcher {

    static let shared = NowPlayingWatcher()

    private let queue = DispatchQueue(label: "videoboy.now-playing", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastTrackKey: String?
    private var artwork: ImageBuffer?

    /// Self-QA sets this so a check can publish its own track without the real
    /// players overwriting it (and without an Automation prompt).
    static var disabledForChecks = false

    /// Starts polling (idempotent).
    func start() {
        guard timer == nil, !Self.disabledForChecks else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        Log.info(.app, "now playing: watching Apple Music / Spotify")
    }

    /// One query per player; the first that is playing wins.
    private func poll() {
        let now = CACurrentMediaTime()
        for player in ["Music", "Spotify"] where isRunning(player) {
            switch query(player) {
            case .playing(var track, let key):
                if key != lastTrackKey {
                    lastTrackKey = key
                    artwork = player == "Music" ? musicArtwork() : nil
                }
                track.artwork = artwork
                NowPlayingHub.shared.publish(track, status: player, at: now)
                return
            case .notPlaying:
                continue
            case .refused(let why):
                NowPlayingHub.shared.publish(nil, status: why, at: now)
                return
            }
        }
        NowPlayingHub.shared.publish(nil, status: "Nothing playing in Music or Spotify", at: now)
    }

    private enum Answer {
        case playing(NowPlayingTrack, key: String)
        case notPlaying
        case refused(String)
    }

    private func isRunning(_ app: String) -> Bool {
        let identifier = app == "Music" ? "com.apple.Music" : "com.spotify.client"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    private func query(_ app: String) -> Answer {
        let separator = "\u{1F}"
        let source = """
            tell application "\(app)"
                if player state is not playing then return ""
                set t to current track
                set d to duration of t
                if d > 1000 then set d to d / 1000
                return (name of t) & "\(separator)" & (artist of t) & "\(separator)" & (album of t) ¬
                    & "\(separator)" & (player position as text) & "\(separator)" & (d as text)
            end tell
            """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: the Automation permission was refused.
            return code == -1743
                ? .refused("Videoboy may not read \(app) — allow it in System Settings ▸ Privacy ▸ Automation")
                : .refused("\(app) did not answer (\(code))")
        }
        let parts = (result.stringValue ?? "").components(separatedBy: separator)
        guard parts.count == 5, !parts[0].isEmpty else { return .notPlaying }
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
        let position = number(parts[3]) ?? 0
        let duration = number(parts[4]) ?? 0
        let track = NowPlayingTrack(
            title: parts[0], artist: parts[1].isEmpty ? nil : parts[1],
            album: parts[2].isEmpty ? nil : parts[2],
            progress: duration > 0 ? min(max(position / duration, 0), 1) : nil)
        return .playing(track, key: parts[0] + "|" + parts[1] + "|" + parts[2])
    }

    /// The current track's artwork from Music, scaled to 256 px, or nil.
    private func musicArtwork() -> ImageBuffer? {
        let source = """
            tell application "Music"
                if (count of artworks of current track) is 0 then return missing value
                return raw data of artwork 1 of current track
            end tell
            """
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error),
              let image = NSImage(data: descriptor.data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? ImageBuffer(width: side, height: side, pixels: pixels) : nil
    }
}
