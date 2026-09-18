//
//  FSUAEHost.swift — a real Amiga, as a source.
//
//  Purpose : Runs FS-UAE as a separate program, captures its window, and hands the
//            frames to the graph. This is what makes "the Amiga" an input the mixer
//            can cut to like any other.
//  Inputs  : a TitlerProgram, and whatever the machine draws.
//  Outputs : ImageBuffers, through `EmulatorHost`.
//  Connects: EmulatedTitlerNode (which turns them into textures), EmulatorController,
//            FSUAEConfiguration, AmigaCommandBridge.
//  Extend  : another emulator is another `EmulatorHost`. Nothing above this knows
//            which one is running.
//
//  ── WHY A SEPARATE PROCESS AND A SCREEN CAPTURE ─────────────────────────────────
//
//  FS-UAE is GPL. This app is distributed, so linking it would relicense the whole
//  app — which makes "launch it and never link it" not a workaround but the correct
//  and simplest compliance.
//
//  The consequence is that there is no API to ask it for a frame. There are three ways
//  round that: patch the emulator (which is the linking problem again), have it write
//  frames to a file (slow, and it has no such mode), or capture its window. macOS has
//  a first-class API for the third — ScreenCaptureKit — which composites the window
//  whether or not it is in front, and delivers frames on its own thread.
//
//  The cost is ONE PERMISSION, granted once, and the honest failure when it is not:
//  the panel says what is missing rather than showing a black rectangle.
//
//  ── AND WHY IT CANNOT JITTER THE MIX ────────────────────────────────────────────
//
//  Capture runs on its own queue and writes the newest frame into a slot behind a
//  lock. The render loop takes whatever is there. It never waits for a frame, never
//  asks the emulator for one, and never blocks on the capture queue — a machine that
//  has stalled shows its last frame rather than stalling the mixer with it.
//

import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoboyCore

/// FS-UAE, launched and captured.
final class FSUAEHost: NSObject, EmulatorHost, SCStreamOutput, SCStreamDelegate {

    /// Why it cannot run, or nil when it can.
    private(set) var unavailableReason: String?

    /// Whether a machine is running and frames are arriving.
    var isReady: Bool { runningApp?.isTerminated == false }

    /// FS-UAE has no script port of its own; the commands go through the shared
    /// drawer and the ARexx listener inside the machine. See `AmigaCommandBridge`.
    var supportsCommands: Bool { true }

    /// Called on the main thread when the running state changes, for the panel.
    var onStateChanged: (() -> Void)?

    /// The emulator, as a running application rather than a child process.
    ///
    /// LAUNCHED WITHOUT ACTIVATING, which is the whole reason this is not a `Process`.
    /// A GUI application started by `Process.run()` brings itself to the front, and the
    /// moment Amiberry has focus SDL grabs the pointer — so starting the titler took
    /// the mouse for the whole machine until you clicked somewhere else. Nothing in
    /// this app was asking for that; it is simply what launching an app does.
    /// `NSWorkspace.OpenConfiguration.activates = false` is the documented way not to.
    private var runningApp: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.videoboy.fsuae-capture", qos: .userInitiated)

    private let frameLock = NSLock()
    private var newestFrame: ImageBuffer?
    private var framesCaptured = 0

    /// The window title FS-UAE is asked for, which is how the capture finds it.
    ///
    /// Matched as a PREFIX: FS-UAE appends the machine to whatever title it is given,
    /// so "Videoboy Amiga" becomes "Videoboy Amiga · Amiga 1200". An exact match here
    /// silently finds nothing, which looks exactly like the permission being denied.
    private let windowTitlePrefix: String

    /// Window titles the capture will accept, by emulator.
    ///
    /// Amiberry titles its window "Amiberry - [<config name>]" rather than taking a
    /// title from the config, so matching on one prefix is not enough. Both are tried;
    /// the first that exists wins.
    private var acceptedTitlePrefixes: [String] {
        [windowTitlePrefix, "Amiberry"]
    }

    private(set) var bootedProgram: TitlerProgram?

    /// Where the config and the shared drawer live.
    let workspace: URL

    init(workspace: URL, windowTitlePrefix: String = "Videoboy Amiga") {
        self.workspace = workspace
        self.windowTitlePrefix = windowTitlePrefix
        super.init()
        if !Self.emulatorPath() {
            unavailableReason = AmiberryInstallation.installationHint
        }
    }

    // MARK: - Running

    /// Which emulator to launch, and its config.
    ///
    /// AMIBERRY FIRST, FS-UAE as a fallback. Amiberry's core emulates the protection
    /// dongle Scala needs, its AROS is a decade newer, and it restores a save state
    /// from the command line. FS-UAE stays because it works and because having two
    /// proves nothing above this line depends on which one is running.
    static func emulator() -> (bundle: String, executable: String, configName: String)? {
        if AmiberryInstallation.isInstalled() {
            return (AmiberryInstallation.applicationPath,
                    AmiberryInstallation.executablePath, "videoboy-amiga.uae")
        }
        if FSUAEInstallation.isInstalled() {
            return (FSUAEInstallation.applicationPath,
                    FSUAEInstallation.executablePath, "videoboy-amiga.fs-uae")
        }
        return nil
    }

    private static func emulatorPath() -> Bool { emulator() != nil }

    @discardableResult
    func boot(_ program: TitlerProgram) -> Bool {
        guard let emulator = Self.emulator() else {
            unavailableReason = AmiberryInstallation.installationHint
            Log.warn(.titler, unavailableReason ?? "")
            return false
        }
        let config = workspace.appendingPathComponent(emulator.configName)
        guard FileManager.default.fileExists(atPath: config.path) else {
            unavailableReason = "No machine has been set up yet. Press SET UP, or run "
                + "scripts/amiga.sh setup."
            Log.warn(.titler, unavailableReason ?? "")
            return false
        }

        // An emulator already running is NOT a reason to start a second one. Two
        // machines on the same shared drawer both consume the command files, so half
        // the commands go to a window nobody is watching — and both windows carry the
        // same title, so the capture attaches to whichever it finds first.
        if let runningApp, !runningApp.isTerminated {
            Log.info(.titler, "an emulator is already running; reusing it")
            return true
        }

        shutdown()

        // THE MOUSE, AT THE LAYER BELOW THE EMULATOR'S OWN SETTING.
        //
        // Amiberry 8 is built on SDL3, and SDL captures the pointer when its window has
        // focus. `mouse_untrap=both` in the config governs Amiberry; these govern SDL
        // underneath it. The parent environment is carried through rather than
        // replaced, or PATH and the display environment go with it.
        var environment = ProcessInfo.processInfo.environment
        environment["SDL_MOUSE_AUTO_CAPTURE"] = "0"
        environment["SDL_MOUSE_FOCUS_CLICKTHROUGH"] = "1"

        let configuration = NSWorkspace.OpenConfiguration()
        // THE IMPORTANT LINE. Without it the emulator comes to the front on launch,
        // takes the keyboard and mouse with it, and the machine is unusable until you
        // click back into something else. This is a titler: it should arrive behind the
        // window that is driving it and stay there.
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.arguments = emulator.configName.hasSuffix(".uae")
            ? ["-f", config.path]
            : [config.path]
        configuration.environment = environment

        let bundleURL = URL(fileURLWithPath: emulator.bundle)
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
            [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.unavailableReason =
                        "Could not start the emulator: \(error.localizedDescription)"
                    Log.error(.titler, self.unavailableReason ?? "")
                    self.onStateChanged?()
                    return
                }
                self.runningApp = application
                self.watchForTermination(of: application)
                self.unavailableReason = nil

                // ASK OFF THE MAIN THREAD. `CGRequestScreenCaptureAccess` BLOCKS its
                // caller until the dialog is answered, and the main thread is also the
                // render thread — the display link runs on `.main`. Calling it here
                // stopped the whole app dead: the prompt appeared, every event stopped
                // being processed, the pointer did nothing anywhere near the window, and
                // it only came back when the click that answered the dialog let main
                // run again. That is the "I lose control of my cursor" report, and it
                // was never the emulator grabbing it.
                //
                // Nothing needs the answer synchronously. The capture retries for ten
                // seconds either way, so granting the permission mid-retry is picked up
                // on the next attempt, and refusing it ends with the panel saying so.
                if !Self.hasScreenRecordingPermission {
                    Log.info(.titler, "requesting Screen Recording permission (off-thread)")
                    // Remembered BEFORE the ask, not after: the answer may never come
                    // back if the dialog is dismissed, and what matters later is that
                    // the app has been through this once — which is what distinguishes
                    // "it will ask you" from "the tick is stale".
                    Self.rememberWeAsked()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let granted = Self.requestScreenRecordingPermission()
                        DispatchQueue.main.async {
                            Log.info(.titler, "Screen Recording "
                                + (granted ? "granted" : "not granted"))
                            self.onStateChanged?()
                        }
                    }
                }

                // BELT AND BRACES on the focus. `activates = false` covers the launch,
                // but an SDL window can still raise itself once it exists, and one
                // frame of focus is enough for the pointer to be captured. Taking it
                // back costs nothing when it was never lost.
                NSApp.activate(ignoringOtherApps: true)

                Log.info(.titler, "\(bundleURL.lastPathComponent) started for "
                    + "\(program.name) (pid \(application?.processIdentifier ?? -1)), "
                    + "without activating it")
                self.onStateChanged?()
                self.startCapture(attempt: 0)
            }
        }

        self.bootedProgram = program
        self.unavailableReason = nil
        return true
    }

    /// Notices the emulator going away, so the panel stops claiming it is running.
    ///
    /// A `Process` had `terminationHandler`; a launched application does not, so this is
    /// the equivalent. Without it a quit emulator leaves the panel lit and the capture
    /// retrying against a window that no longer exists.
    private func watchForTermination(of application: NSRunningApplication?) {
        guard let application else { return }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        let pid = application.processIdentifier
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let ended = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard ended?.processIdentifier == pid else { return }
            Log.info(.titler, "the emulator exited")
            self?.stopCapture()
            self?.runningApp = nil
            self?.onStateChanged?()
        }
    }


    func shutdown() {
        stopCapture()
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        if let runningApp, !runningApp.isTerminated {
            runningApp.terminate()
        }
        runningApp = nil
        bootedProgram = nil
        frameLock.lock()
        newestFrame = nil
        framesCaptured = 0
        frameLock.unlock()
    }

    /// Brings the emulator's own window to the front, so a person can use it directly.
    ///
    /// The whole machine being reachable matters: the panel drives the handful of
    /// things a performance needs, and everything else — loading a script, fixing a
    /// page — is done in the software itself.
    func bringToFront() {
        guard let runningApp, !runningApp.isTerminated else { return }
        runningApp.activate(options: [.activateAllWindows])
    }

    // MARK: - Frames

    func latestFrame() -> ImageBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return newestFrame
    }

    /// How many frames have arrived, for the panel's readout.
    var capturedFrameCount: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return framesCaptured
    }

    /// The same count, as the graph node reads it to tell a new picture from the one it
    /// has already uploaded. See `EmulatorHost.frameGeneration`.
    var frameGeneration: UInt64 {
        frameLock.lock(); defer { frameLock.unlock() }
        return UInt64(framesCaptured)
    }

    func send(_ step: TitlerBootStep) {
        // Commands reach the machine through the shared drawer, not through here —
        // see AmigaCommandBridge. This exists for the EmulatorHost protocol and is
        // deliberately not a second, quieter path into the machine.
        Log.info(.titler, "FS-UAE host ignoring \(step.description); "
            + "commands go through the shared drawer")
    }

    // MARK: - Capture

    /// Whether this app really has Screen Recording, asked of the system.
    ///
    /// `CGPreflightScreenCaptureAccess` reports the ACTUAL state. Everything below
    /// exists because the first version of this file simply assumed a capture failure
    /// meant the permission was off, and said so in a confident sentence — which told
    /// someone they had blocked a permission they had never been asked for, while the
    /// real fault was something else entirely. An error message that guesses is worse
    /// than one that admits it does not know.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for it, which is what actually raises the system prompt.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Whether macOS LISTS this app under Screen Recording, regardless of whether the
    /// grant actually applies to this build.
    ///
    /// The two are different, and the difference is the whole problem. The Settings
    /// pane matches by BUNDLE ID, so the row is there and ticked. TCC matches the
    /// grant by CODE SIGNATURE, which changes on every ad-hoc build. So a person sees
    /// a ticked box, the app cannot capture, and there is nothing on screen connecting
    /// the two facts. That is the complaint, and it is a fair one.
    ///
    /// There is no API to read the Settings list, so this is inferred: if the app has
    /// been asked before — the preference exists — but preflight says no, the tick is
    /// stale rather than absent.
    static var hasBeenAskedBefore: Bool {
        UserDefaults.standard.bool(forKey: askedKey)
    }

    private static let askedKey = "videoboy.screenRecording.asked"

    static func rememberWeAsked() {
        UserDefaults.standard.set(true, forKey: askedKey)
    }

    /// What to tell someone about Screen Recording, right now, in words they can act on.
    ///
    /// Three genuinely different situations, which used to produce one message:
    ///
    ///   granted        nothing to say
    ///   never asked    it will ask; say so, so the prompt is expected
    ///   asked before,  THE TICK IS LYING. This is the one that wasted days: the box is
    ///   still denied   ticked, the app cannot capture, and "check Screen Recording"
    ///                  sends you to a pane that already looks correct.
    static var screenRecordingAdvice: String? {
        if hasScreenRecordingPermission { return nil }
        guard hasBeenAskedBefore else {
            return "macOS will ask for Screen Recording when the machine starts. "
                + "That is how the emulator's picture reaches Videoboy."
        }
        return "Screen Recording is listed for Videoboy but is NOT being granted to "
            + "this build.\n\nmacOS ticks the box by app name and checks the grant by "
            + "code signature, and this build's signature is new — so the tick is real "
            + "and stale at the same time.\n\nRemove Videoboy from the list, then add "
            + "it again. To stop it recurring, run scripts/signing-identity.sh once."
    }

    /// What actually went wrong, distinguishing the permission from everything else.
    static func captureFailureReason(_ error: Error) -> String {
        guard !hasScreenRecordingPermission else {
            // The permission is GRANTED, so whatever happened is not that. Report the
            // real error rather than sending someone to a settings pane where they will
            // find the switch already on and conclude the app is broken.
            return "The emulator's window could not be captured: "
                + "\(error.localizedDescription). Screen Recording IS allowed, so this "
                + "is something else — try STOP then START."
        }

        // Genuinely denied. Worth naming the usual cause, which is not the person:
        // this app is ad-hoc signed, so every rebuild changes its signature, and macOS
        // stops matching a permission that was granted to the previous build. It reads
        // exactly like a permission you refused and never touched.
        return "Screen Recording is not granted to Videoboy. System Settings > "
            + "Privacy & Security > Screen Recording, and switch Videoboy on. If it is "
            + "already on, the app was rebuilt since you granted it — macOS keys that "
            + "permission to the exact build. Turn it off and on again, or run: "
            + "tccutil reset ScreenCapture com.spencerstarnes.videoboy"
    }

    private func startCapture(attempt: Int) {
        // Up to ten seconds of retries. An Amiga takes a few seconds to put a window
        // up, and a machine under load can take longer; failing at the first look
        // would report "no window" for a machine that is simply still starting.
        let maximumAttempts = 20

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                let prefixes = self.acceptedTitlePrefixes
                guard let window = content.windows.first(where: { candidate in
                    let title = candidate.title ?? ""
                    return prefixes.contains { title.hasPrefix($0) }
                }) else {
                    if attempt < maximumAttempts, self.runningApp?.isTerminated == false {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self.startCapture(attempt: attempt + 1)
                    } else {
                        await MainActor.run {
                            self.unavailableReason =
                                "The emulator is running but its window could not be "
                                + "found to capture."
                            self.onStateChanged?()
                        }
                    }
                    return
                }
                try await self.beginStream(on: window)
            } catch {
                await MainActor.run {
                    self.unavailableReason = Self.captureFailureReason(error)
                    Log.error(.titler, self.unavailableReason ?? "")
                    self.onStateChanged?()
                }
            }
        }
    }

    private func beginStream(on window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()

        // CROP THE WINDOW CHROME. A window capture includes the title bar, and the
        // emulator's picture is only the content beneath it. Left in, the bar is baked
        // into every frame that reaches the graph — and it also made a self-QA check
        // pass for the wrong reason, because grey chrome counts as "not blank".
        //
        // The inset is the standard macOS title bar. It is a magic number only in the
        // sense that the system's title bar is: there is no API to ask another
        // application's window where its content begins.
        let titleBarHeight: CGFloat = 28
        if window.frame.height > titleBarHeight * 2 {
            configuration.sourceRect = CGRect(
                x: 0, y: titleBarHeight,
                width: window.frame.width,
                height: window.frame.height - titleBarHeight)
            // Required with sourceRect, or ScreenCaptureKit scales the cropped region
            // back into the full destination and the crop does nothing visible.
            configuration.destinationRect = CGRect(
                x: 0, y: 0,
                width: StandardDefinition.width, height: StandardDefinition.height)
            configuration.scalesToFit = true
        }

        // Captured at the PROJECT'S geometry, not the window's. Everything in this
        // graph is 720x480, and resampling once here is cheaper and cleaner than
        // carrying an odd-sized texture through the chain to be resampled later.
        configuration.width = StandardDefinition.width
        configuration.height = StandardDefinition.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3
        // The emulator's own rate, not ours. Asking for more produces duplicates and
        // wastes work; asking for less makes it stutter independently of the mix.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(
            self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream

        await MainActor.run {
            Log.info(.titler, "capturing \"\(window.title ?? "")\"")
            self.unavailableReason = nil
            self.onStateChanged?()
        }
    }

    private func stopCapture() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let image = FSUAEHost.imageBuffer(from: pixelBuffer) else { return }
        frameLock.lock()
        newestFrame = image
        framesCaptured += 1
        frameLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            Log.error(.titler, "capture stopped: \(error.localizedDescription)")
            self?.unavailableReason = "The capture stopped: \(error.localizedDescription)"
            self?.onStateChanged?()
        }
    }

    /// Turns a captured BGRA buffer into the graph's RGBA one.
    ///
    /// Row by row rather than pixel by pixel where possible: a captured buffer is
    /// padded to a row alignment, so the rows have to be walked, but the swap inside a
    /// row is a tight loop over bytes rather than a call per pixel.
    static func imageBuffer(from pixelBuffer: CVPixelBuffer) -> ImageBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = base.assumingMemoryBound(to: UInt8.self)

        // Built as one array and handed to the buffer, rather than written into an
        // existing one: `pixels` is private(set), and the whole-array initialiser is
        // both the supported route and a single allocation.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        rgba.withUnsafeMutableBufferPointer { destination in
            guard let out = destination.baseAddress else { return }
            for y in 0..<height {
                let row = source + y * stride
                let outRow = out + y * width * 4
                for x in 0..<width {
                    let i = x * 4
                    // BGRA in, RGBA out.
                    outRow[i] = row[i + 2]
                    outRow[i + 1] = row[i + 1]
                    outRow[i + 2] = row[i]
                    outRow[i + 3] = 255
                }
            }
        }
        return ImageBuffer(width: width, height: height, pixels: rgba)
    }
}
