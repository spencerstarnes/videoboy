//
//  EmulatedTitler.swift — running real vintage titling software as a source (SPEC 18.2).
//
//  Purpose : Boot something like Broadcast Titler II on an emulated Amiga, drive it
//            from a modern panel, and take its output as a video source so it can be
//            overlaid on the programme.
//  Inputs  : a `TitlerProgram` (which software), and text/controls from the panel.
//  Outputs : frames, as a source in the graph.
//  Connects: EmulatorHost (the out-of-process emulator), the EMU tab in the centre
//            column, the render graph.
//  Extend  : a new piece of software is a `TitlerProgram` entry plus a boot recipe.
//            It should need no code.
//
//  ── TWO CONSTRAINTS THAT SHAPE ALL OF THIS ──────────────────────────────────────
//
//  LICENSING. libretro emulator cores are GPL. This app is distributed, so a GPL core
//  may never be linked into it — it runs OUT OF PROCESS and is spoken to over a pipe,
//  which is why `EmulatorHost` is a protocol describing a separate process rather
//  than an emulator API. That is not a design preference; linking it would relicense
//  the whole app.
//
//  ASSETS. Kickstart ROMs and Broadcast Titler disk images are copyrighted. They are
//  USER-SUPPLIED, referenced by path, never bundled and never downloaded. Everything
//  here therefore has to degrade to a labelled, greyed state when they are absent —
//  which is also what makes it testable without them.
//

import Foundation

/// One piece of vintage software this app knows how to drive.
public struct TitlerProgram: Equatable, Codable, Sendable, Identifiable {
    public var id: String { name }

    public let name: String
    /// The machine it needs, which decides the core.
    public let platform: Platform
    /// The machine to configure the core as. Defaults to the platform's plainest.
    public let machine: Machine
    /// What a person has to supply before it can run, in plain words.
    public let requires: [String]
    /// The boot recipe — see `TitlerBootStep`.
    public let boot: [TitlerBootStep]
    /// The name of the software's script port, when it has one.
    ///
    /// Scala's is "SCALA". A program with a port is driven by commands; one without
    /// falls back to keystrokes, which is why this is optional rather than assumed.
    public let scriptPort: String?

    /// Which machine the core should be configured as.
    ///
    /// Separate from the platform because "Amiga" is not one machine. Scala MM300
    /// wants an A1200 with fast RAM and will crawl or refuse on a stock A500, and an
    /// accelerator changes the core's CPU and memory settings rather than the core
    /// itself.
    public enum Machine: String, Codable, Sendable {
        case amiga500
        case amiga1200
        /// An A1200 with a Vampire accelerator — 68080, lots of fast RAM.
        case amiga1200Vampire

        public var displayName: String {
            switch self {
            case .amiga500: "Amiga 500"
            case .amiga1200: "Amiga 1200"
            case .amiga1200Vampire: "Amiga 1200 + Vampire"
            }
        }

        /// The core options this machine needs, as a libretro core would take them.
        ///
        /// PUAE has no 68080, so a Vampire is approximated with the fastest CPU it
        /// does offer and the memory an accelerated machine has. Worth saying plainly:
        /// this is a machine that RUNS the software comfortably, not a cycle-accurate
        /// Vampire.
        public var coreOptions: [String: String] {
            switch self {
            case .amiga500:
                return ["puae_model": "A500", "puae_cpu_compatibility": "normal"]
            case .amiga1200:
                return [
                    "puae_model": "A1200",
                    "puae_cpu_compatibility": "normal",
                    "puae_fastmem": "8"
                ]
            case .amiga1200Vampire:
                return [
                    "puae_model": "A1200",
                    "puae_cpu_model": "68040",
                    "puae_cpu_compatibility": "turbo",
                    "puae_fastmem": "64",
                    "puae_video_resolution": "hires"
                ]
            }
        }
    }

    public enum Platform: String, Codable, Sendable {
        case amiga
        case atariST
        case dos

        public var displayName: String {
            switch self {
            case .amiga: "Amiga"
            case .atariST: "Atari ST"
            case .dos: "DOS"
            }
        }

        /// The libretro core normally used for this platform. Named, not bundled.
        public var suggestedCore: String {
            switch self {
            case .amiga: "puae_libretro"
            case .atariST: "hatari_libretro"
            case .dos: "dosbox_pure_libretro"
            }
        }
    }

    public init(
        name: String, platform: Platform, requires: [String], boot: [TitlerBootStep],
        machine: Machine = .amiga500, scriptPort: String? = nil
    ) {
        self.name = name
        self.platform = platform
        self.machine = machine
        self.scriptPort = scriptPort
        self.requires = requires
        self.boot = boot
    }
}

/// One line of script sent to software that has a script port.
///
/// ── WHY THIS EXISTS, and why it changed the design ──────────────────────────────
///
/// Scala MM300 has an ARexx port. The CU Amiga disc ships `Scala/ARexx` with a worked
/// example that "communicates with other applications and brings the results back to
/// Scala using Scala Lingo", plus an `ARexx.lha` in the install set.
///
/// That matters more than it sounds. Driving vintage software by synthesising
/// keystrokes means knowing where every cursor is and hoping nothing shifted; a script
/// port means SAYING WHAT YOU WANT. Setting a line of text becomes one command instead
/// of "move here, clear that, type this", and it can be checked — a command either
/// arrived or it did not.
///
/// It is also what makes the rest tractable: a control that can be driven by a command
/// can be driven by a fader, by MIDI, or by the beat clock, because all of those
/// already produce values and none of them can type.
///
/// ── WHY VERB-PLUS-ARGUMENTS AND NOT A CASE PER COMMAND ──────────────────────────
///
/// The first version of this was an enum with a case per intent — `setText`,
/// `setColour`, `goToPage`. Reading the disc killed that: Scala has no named fields to
/// set, it has a screen with coordinates, and every other program will bring its own
/// verbs too. An enum would have needed a case per verb per program.
///
/// A verb and its arguments is the shape EVERY one of these languages actually has —
/// Scala Lingo, ARexx, and the keystroke macros underneath them — so the wire type is
/// that shape, and each program's DIALECT (see `ScalaLingo`) builds the lines. The app
/// stays generic; the vocabulary is per program, which is exactly where the
/// differences live.
public struct TitlerCommand: Equatable, Codable, Sendable {

    /// The command word: `TEXT`, `WIPE`, `FONT`.
    public let verb: String
    /// Its arguments, in order.
    public let arguments: [Argument]
    /// What this does, in plain words — for the log, the tooltip and the panel.
    ///
    /// Carried rather than derived because only the dialect knows that `speed 1` means
    /// FAST. A generic renderer would have to guess, and would guess wrong.
    public let explanation: String

    /// One argument, typed by HOW IT MUST BE WRITTEN rather than by what it means.
    ///
    /// The distinction that matters to a script parser is quoting: a bare word is a
    /// keyword, a quoted string is data. Getting that wrong is how `TEXT 20 40 Hello
    /// World` becomes two arguments and a syntax error.
    public enum Argument: Equatable, Codable, Sendable {
        /// A bare keyword: `SPEED`, `south`, `lace`, `Franklin.font`.
        case word(String)
        /// A number. Written without a decimal point when it is whole, because Scala's
        /// own scripts write `speed 5` and not `speed 5.0`.
        case number(Double)
        /// A string, which gets quoted and escaped.
        case text(String)

        var rendered: String {
            switch self {
            case .word(let word):
                return word
            case .number(let value):
                return value == value.rounded() && abs(value) < 1e9
                    ? String(Int(value))
                    : String(format: "%.3f", value)
            case .text(let string):
                // Scala Lingo has no escape for a double quote inside a quoted string,
                // so one is turned into a single quote rather than being allowed to
                // end the argument early and corrupt every line after it.
                return "\"" + string.replacingOccurrences(of: "\"", with: "'") + "\""
            }
        }
    }

    public init(verb: String, arguments: [Argument], explanation: String) {
        self.verb = verb
        self.arguments = arguments
        self.explanation = explanation
    }

    /// The script line this becomes.
    public var line: String {
        ([verb] + arguments.map(\.rendered)).joined(separator: " ")
    }

    /// A raw line, for anything the typed constructors do not cover.
    ///
    /// Present deliberately: a wrapper that cannot express what the underlying system
    /// can is a wrapper people work around rather than with.
    public static func raw(_ line: String, explanation: String = "raw script line") -> TitlerCommand {
        let parts = line.split(separator: " ", maxSplits: 1)
        return TitlerCommand(
            verb: String(parts.first ?? ""),
            arguments: parts.count > 1 ? [.word(String(parts[1]))] : [],
            explanation: explanation)
    }
}

/// One step of getting a program from cold boot to the point where it will take text.
///
/// This is the "smart config macro": a recipe, as data, rather than a hand-written
/// script per program. Data because a recipe that is data can be edited by someone
/// who does not write Swift, shipped as a file, and — the part that matters here —
/// TESTED without an emulator, by checking the steps rather than the pixels.
public enum TitlerBootStep: Equatable, Codable, Sendable {
    /// Wait for the machine to settle, in emulated seconds.
    case wait(seconds: Double)
    /// Wait until the screen stops changing, which is how you know a load finished
    /// without timing it by hand on a machine that may run at any speed.
    case waitForStableScreen(timeout: Double)
    /// Press a key, by name: "return", "f1", "escape".
    case key(String)
    /// Type a string, one character at a time.
    case type(String)
    /// Click at a position given in FRACTIONS of the screen, so a recipe does not
    /// break when the emulated resolution changes.
    case click(x: Double, y: Double)
    /// Restore a save state, which is by far the most reliable way to land in the
    /// right place — see the note on `TitlerProgram.boot` below.
    case loadState(named: String)
    /// Send a command to the program's script port. Preferred over `.type` and
    /// `.key` wherever the software has one.
    case command(TitlerCommand)

    /// A short description, for the progress readout while a program boots.
    public var description: String {
        switch self {
        case .wait(let seconds): "waiting \(String(format: "%.1f", seconds))s"
        case .waitForStableScreen: "waiting for the screen to settle"
        case .key(let name): "pressing \(name)"
        case .type(let text): "typing \"\(text)\""
        case .click(let x, let y): "clicking \(Int(x * 100))%, \(Int(y * 100))%"
        case .loadState(let name): "restoring \(name)"
        case .command(let command): "sending \(command.line)"
        }
    }
}

/// The software this app ships recipes for.
///
/// Recipes only. None of these programs are included — every one needs disk images
/// the person running it must already own.
public enum TitlerLibrary {

    public static let programs: [TitlerProgram] = [
        TitlerProgram(
            name: "Broadcast Titler II",
            platform: .amiga,
            requires: [
                "An Amiga Kickstart ROM (1.3 or 2.0)",
                "Broadcast Titler II disk images (.adf)",
                "A libretro Amiga core (puae_libretro)"
            ],
            // Deliberately short. Driving a boot by timed keystrokes is fragile —
            // a disk that loads a second slower puts every later step in the wrong
            // place. The reliable path is to boot ONCE by hand, save a state sitting
            // at the text entry screen, and land there every time after.
            boot: [
                .waitForStableScreen(timeout: 60),
                .loadState(named: "broadcast-titler-text-entry")
            ]
        ),
        TitlerProgram(
            name: "Deluxe Paint IV",
            platform: .amiga,
            requires: [
                "An Amiga Kickstart ROM",
                "Deluxe Paint IV disk images (.adf)",
                "A libretro Amiga core (puae_libretro)"
            ],
            boot: [
                .waitForStableScreen(timeout: 60),
                .loadState(named: "dpaint-canvas")
            ]
        ),
        TitlerProgram(
            name: "Scala MM300",
            platform: .amiga,
            requires: [
                "An Amiga Kickstart ROM (3.0 or 3.1, for the A1200)",
                "Scala MM300 disk images or a hard-disk image (.adf / .hdf)",
                "A libretro Amiga core (puae_libretro)"
            ],
            // Scala is the slowest of these to come up — it is a whole authoring
            // environment rather than a titler — so the timeout is generous and the
            // save state matters more here than anywhere else.
            boot: [
                .waitForStableScreen(timeout: 120),
                .loadState(named: "scala-mm300-text-page")
            ],
            machine: .amiga1200Vampire,
            // Confirmed on the CU Amiga disc: Scala/ARexx ships a working example and
            // the install set carries ARexx.lha. This is what the text box talks to.
            scriptPort: ScalaLingo.portName
        ),
        TitlerProgram(
            name: "Scala MM400",
            platform: .amiga,
            requires: [
                "An Amiga Kickstart ROM (3.0 or 3.1)",
                "A Scala MM400 disc",
                "Amiberry or FS-UAE"
            ],
            boot: [
                .waitForStableScreen(timeout: 120),
                .loadState(named: "scala-mm400-ready")
            ],
            machine: .amiga1200Vampire,
            // THE SAME PORT as MM300, verified in its binary. Which is the whole reason
            // MM400 was worth trying: the translation layer, the command vocabulary and
            // every one of the nineteen controls work against it unchanged.
            scriptPort: ScalaLingo.portName
        )
    ]
}

/// What an emulator has to be able to do for this app to drive it.
///
/// A protocol describing a SEPARATE PROCESS, not an emulator API. GPL cores cannot be
/// linked into a distributed app, so the real implementation launches a helper and
/// talks to it; this is the shape of that conversation.
public protocol EmulatorHost: AnyObject {
    /// Whether a core and the assets it needs are actually present.
    var isReady: Bool { get }
    /// Why it is not ready, in words a person can act on.
    var unavailableReason: String? { get }

    /// Starts the program. Returns false when something it needs is missing.
    func boot(_ program: TitlerProgram) -> Bool
    /// The most recent frame, or nil before the first one arrives.
    func latestFrame() -> ImageBuffer?
    /// Increments every time a NEW frame arrives, so a consumer can tell a fresh
    /// picture from the one it already has.
    ///
    /// This exists because the graph node caches its uploaded texture — an upload per
    /// frame would allocate on the render path, which the house rules forbid — and it
    /// had no way to know when to stop. It relied on an `invalidateFrame()` call that
    /// NOTHING made, so the emulator source uploaded the first frame it ever saw, which
    /// during boot is a blank window, and froze there for ever. Routing the machine to
    /// a channel produced a permanently empty rectangle.
    ///
    /// A counter rather than a flag: a flag has to be cleared by whoever sets it, which
    /// is exactly the arrangement that failed. Asking "is this the frame I have?" needs
    /// no cooperation from anyone.
    var frameGeneration: UInt64 { get }
    /// Sends one boot step or one piece of user input.
    func send(_ step: TitlerBootStep)
    /// Whether this host can reach a script port at all.
    var supportsCommands: Bool { get }
    /// Stops and releases the process.
    func shutdown()
}

/// An emulator that is not there.
///
/// The state the app is in on any machine without a core and the disk images — which
/// is every machine until someone supplies them. It reports WHY rather than failing
/// silently, because "nothing happened" is the least useful thing a missing dependency
/// can say.
public final class UnavailableEmulatorHost: EmulatorHost {
    public let unavailableReason: String?
    public var isReady: Bool { false }

    public init(reason: String) {
        self.unavailableReason = reason
    }

    public func boot(_ program: TitlerProgram) -> Bool {
        Log.warn(.titler, "cannot boot \(program.name): \(unavailableReason ?? "unavailable")")
        return false
    }
    public func latestFrame() -> ImageBuffer? { nil }
    public var frameGeneration: UInt64 { 0 }
    public func send(_ step: TitlerBootStep) {}
    public func shutdown() {}
    public var supportsCommands: Bool { false }
}

/// An emulator that produces a test picture and records what it was told.
///
/// Not only for tests. It is what the EMU tab runs against while no core is
/// installed, so the panel, the boot sequencing and the text plumbing can all be
/// built and looked at before anyone owns a Kickstart ROM.
public final class MockEmulatorHost: EmulatorHost {
    public var isReady: Bool = true
    public var unavailableReason: String? { isReady ? nil : "the mock was switched off" }

    /// Every step it has been sent, in order — which is how a boot recipe is checked
    /// without an emulator to run it on.
    public private(set) var received: [TitlerBootStep] = []
    public private(set) var bootedProgram: TitlerProgram?

    /// Text typed so far, assembled from the `.type` steps.
    public var typedText: String {
        received.compactMap { if case .type(let text) = $0 { return text } else { return nil } }
            .joined()
    }

    private var frame: ImageBuffer?

    public init() {}

    public func boot(_ program: TitlerProgram) -> Bool {
        guard isReady else { return false }
        bootedProgram = program
        received.removeAll()
        // A recognisable picture, so "is anything coming out of it" has an answer.
        frame = TestPattern.colorBars()
        frameGeneration += 1
        for step in program.boot { send(step) }
        return true
    }

    public func latestFrame() -> ImageBuffer? { frame }
    public private(set) var frameGeneration: UInt64 = 0

    public func send(_ step: TitlerBootStep) {
        received.append(step)
    }

    public var supportsCommands: Bool { true }

    /// Every command sent to the script port, in order.
    public var commands: [TitlerCommand] {
        received.compactMap { if case .command(let c) = $0 { return c } else { return nil } }
    }

    public func shutdown() {
        bootedProgram = nil
        frame = nil
        frameGeneration += 1
        received.removeAll()
    }
}
