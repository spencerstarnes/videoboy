//
//  main.swift — process entry point.
//
//  Purpose : Starts the AppKit application, or runs a self-QA check and exits.
//            The self-QA path lives inside the app bundle on purpose: macOS grants
//            camera permission to a bundle identifier, so the loopback capture can
//            only be authorised from in here, not from a shell script.
//  Inputs  : command-line arguments.
//            --selfqa <check>   run one self-QA check headlessly and exit
//            --help             print usage
//  Outputs : an app window, or self-QA artifacts under selfqa/out/.
//  Connects: AppDelegate (normal launch), SelfQARunner (the --selfqa path).
//  Extend  : add a flag here only if it must be decided before AppKit starts.
//

import AppKit
import VideoboyCore

/// Parsed form of the command line.
enum LaunchMode {
    case normal
    case selfQA(check: String)
    /// The Copy + Optimize helper (0.4.10): converts one file and exits. Run by the
    /// app as a CHILD PROCESS (OptimizeQueue), so a crash in a decoder or encoder can
    /// never take the show down.
    case optimize(source: String, output: String, preset: String)
    case help
}

/// Reads the command line into a `LaunchMode`. Unknown arguments are ignored with a
/// warning rather than refused, so a stray argument never blocks a launch.
func parseLaunchMode(_ arguments: [String]) -> LaunchMode {
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--help", "-h":
            return .help
        case "--optimize":
            guard index + 3 < arguments.count else {
                Log.error(.app, "--optimize needs <source> <output> <preset>")
                return .help
            }
            return .optimize(source: arguments[index + 1], output: arguments[index + 2],
                             preset: arguments[index + 3])
        case "--selfqa":
            guard index + 1 < arguments.count else {
                Log.error(.app, "--selfqa needs a check name (offscreen, loopback, midi)")
                return .help
            }
            return .selfQA(check: arguments[index + 1])
        default:
            Log.warn(.app, "ignoring unrecognised argument '\(arguments[index])'")
        }
        index += 1
    }
    return .normal
}

let usage = """
Videoboy \(Videoboy.version)

  Videoboy                    launch the app
  Videoboy --selfqa <check>   run a self-QA check and exit
                              checks: loopback, offscreen, displays
  Videoboy --optimize <in> <out> <performance|compact>
                              convert one clip for Copy + Optimize and exit;
                              prints "progress <done> <total>" lines
  Videoboy --help             this message
"""

Log.info(.app, Videoboy.banner)

switch parseLaunchMode(CommandLine.arguments) {
case .help:
    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
    exit(0)

case .optimize(let source, let output, let presetName):
    // Lowest priority: this runs beside a show.
    setpriority(PRIO_PROCESS, 0, 10)
    guard let preset = OptimizePreset(rawValue: presetName) else {
        Log.error(.app, "unknown optimize preset '\(presetName)'")
        exit(2)
    }
    // SIGTERM (Cancel) stops between frames; the caller deletes the partial file.
    signal(SIGTERM, SIG_DFL)
    do {
        let frames = try ClipOptimizer.optimize(
            URL(fileURLWithPath: source), to: URL(fileURLWithPath: output), preset: preset
        ) { done, total in
            FileHandle.standardOutput.write(Data("progress \(done) \(total)\n".utf8))
        }
        FileHandle.standardOutput.write(Data("done \(frames)\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("optimize failed: \(error)\n".utf8))
        exit(1)
    }

case .selfQA(let check):
    // Self-QA runs without a visible UI, but still needs an NSApplication: the
    // AVFoundation capture session requires a run loop to deliver frames.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let exitCode = SelfQARunner.run(check: check)
    exit(exitCode)

case .normal:
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
