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
  Videoboy --help             this message
"""

Log.info(.app, Videoboy.banner)

switch parseLaunchMode(CommandLine.arguments) {
case .help:
    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
    exit(0)

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
