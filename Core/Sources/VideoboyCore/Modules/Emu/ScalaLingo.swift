//
//  ScalaLingo.swift — Scala MM300's real command vocabulary.
//
//  Purpose : The dialect. Everything in here was read OFF THE DISC rather than
//            invented, so a control built on it drives the software instead of
//            drawing a plausible-looking knob that does nothing.
//  Inputs  : native Scala values — a wipe name, a font size, a palette colour.
//  Outputs : `TitlerCommand`s, which render as Scala Lingo script lines.
//  Connects: TitlerControls (the 0...1 layer above it), AmigaCommandBridge (which
//            carries the lines into the machine), EmulatedTitler.
//  Extend  : a new verb is a static function here. A SECOND PROGRAM IS A SECOND FILE
//            like this one — that is the whole shape of the plan: one dialect per
//            piece of software, one generic control layer above them all.
//
//  ── WHERE THIS CAME FROM, AND WHY THAT MATTERS ──────────────────────────────────
//
//  Source: CU Amiga Magazine Super CD-ROM 19 (1998), `Scala/` — specifically
//  `Scala/ARexx/Dir.scala` (the worked ARexx example) and the eleven scripts in
//  `Scala/Scripts/`, which are Scala's own demo material and therefore the best
//  available statement of what the program accepts.
//
//  The first pass at this file was guessed, and every guess was wrong in a way that
//  would have failed silently:
//
//    guessed                        actual (from the disc)
//    ───────────────────────────    ──────────────────────────────────────────────
//    port "SCALA"                   port `rexx_ScalaMM`
//    SETTEXT <field> "<value>"      TEXT <x> <y> "<value>"   — positional, not named
//    SETCOLOUR <field> <index>      PALETTE <hex> <hex> ...  — real RGB, not indices
//    GOTOPAGE "<page>"              GOTO "<event>"           — pages are named EVENTs
//    10 invented wipe names         51 real ones
//
//  A wrong port name is not a bug you can see. The commands leave, nothing receives
//  them, and every slider on the panel moves smoothly and changes nothing — which is
//  the exact failure this whole file exists to prevent.
//

import Foundation

/// Scala MM300's vocabulary, as observed on the disc.
///
/// Namespaced rather than free functions because a second program will bring a second
/// set of verbs with some of the same names, and `ScalaLingo.wipe` versus
/// `BroadcastTitlerLingo.wipe` is the distinction that keeps them apart.
public enum ScalaLingo {

    /// The ARexx port Scala MM300 opens.
    ///
    /// Confirmed in `Scala/ARexx/Dir.scala`: `address 'rexx_ScalaMM'`. Case matters to
    /// ARexx, so this is reproduced exactly as the disc spells it.
    public static let portName = "rexx_ScalaMM"

    // MARK: - Wipes

    /// Scala's instant transition — no animation at all.
    ///
    /// Named rather than written as `wipes[0]`, because "the first one in the list"
    /// is not a reason for it to be the instant one and the list is harvested from the
    /// disc rather than curated. If a future dialect orders them differently this is
    /// the single place that has to change.
    public static let instantWipe = "cut"


    /// Every wipe name found in Scala's own scripts.
    ///
    /// Fifty-one of them, harvested from `Scala/Scripts/*.script`. Kept whole rather
    /// than curated down to a tidy ten: this is a performance tool, and the long tail
    /// — `nuclear`, `ants`, `xword`, `escalator` — is exactly the interesting part.
    /// `ScalaWipes.script` warns that some need "68020 and 2MB chip RAM", which the
    /// A1200 machine profile provides.
    public static let wipes: [String] = [
        "cut", "fade", "cutfade", "fadecutfade", "ccccut", "dissolve", "dump",
        "wipe", "diagonal", "sweep", "push", "strangepush", "slide", "flow",
        "curtain", "checker", "grid8", "diamond", "xword", "swiss", "center",
        "escalator", "ants", "nuclear", "random", "chest", "wallpaper",
        "rollodex", "flipover", "flipcoin", "lowflipcoin", "cube", "turn",
        "bob", "crawl", "excrawl", "newscrollin", "newscrollout", "rollon",
        "line", "link", "sun", "t2", "derreck", "pokabal", "charmblend",
        "smallblend", "smooth", "superimpose", "transpose", "blank"
    ]

    /// The direction modifiers a wipe accepts.
    ///
    /// Observed as the word directly after a wipe name. Not every wipe takes one —
    /// `fade` has no direction — but Scala ignores a direction it cannot use rather
    /// than refusing the line, so offering it uniformly is safe.
    public static let directions: [String] = [
        "north", "south", "east", "west", "southeast", "backwards"
    ]

    /// Fonts Scala's own scripts use, which are the ones installed with it.
    ///
    /// Taken from the `FONT` lines rather than from the disc's `Fonts/` drawer: the
    /// drawer holds a hundred-odd faces, most of them system or demo fonts, while
    /// these seventeen are the ones Scala's authors actually titled with.
    public static let fonts: [String] = [
        "BetonC", "Compact", "CompactL", "Didot", "Franklin", "FranklinC",
        "FuturaB", "FuturaC", "FuturaL", "FuturaX", "Garamond", "Gill",
        "GillN", "GoudyB", "GoudyL", "HelveticaN", "NewsGothic"
    ]

    /// The speed range for a wipe, as Scala counts it.
    ///
    /// The disc uses 1 through 16, clustered hard at 5 and 6. Higher is SLOWER — a
    /// `textwipe dump speed 1` is the instant one — which is worth knowing before
    /// labelling a fader.
    public static let speedRange = 1...16

    /// The font sizes Scala's scripts use, smallest to largest.
    ///
    /// The real span is 12 to 114 points on a 640×512 screen. A fader covering that
    /// whole range is more useful than one covering a "safe" middle, because the two
    /// ends are a caption and a full-screen word.
    public static let fontSizeRange = 12...114

    // MARK: - Verbs

    /// `TEXT <x> <y> "<string>"` — draws a line of text at a position.
    ///
    /// Positional, not named. Scala has no notion of "the title field"; it has a
    /// screen and coordinates on it, which is why the panel above exposes X and Y
    /// rather than pretending there are named slots to fill.
    /// - Parameter line: which line of the page this is. Two TEXT commands with the
    ///   same index replace each other in the send buffer; two with different indices
    ///   both survive, which is how a page carries a headline and a subhead. It is
    ///   deliberately NOT the position — an operator dragging the Y fader is moving one
    ///   line, not creating a new one at every pixel on the way.
    public static func text(x: Int, y: Int, _ string: String, line: Int = 0) -> TitlerCommand {
        TitlerCommand(
            verb: "TEXT",
            arguments: [.number(Double(x)), .number(Double(y)), .text(string)],
            explanation: "draw \"\(string)\" at \(x), \(y)",
            coalesceKey: "TEXT#\(line)")
    }

    /// `WIPE <name> [direction] SPEED <n>` — the transition between pages.
    public static func wipe(_ name: String, direction: String? = nil, speed: Int) -> TitlerCommand {
        var arguments: [TitlerCommand.Argument] = [.word(name)]
        if let direction { arguments.append(.word(direction)) }
        arguments.append(.word("SPEED"))
        arguments.append(.number(Double(clamp(speed, to: speedRange))))
        return TitlerCommand(
            verb: "WIPE", arguments: arguments,
            explanation: "wipe the page with \(name)"
                + (direction.map { " \($0)" } ?? "") + " at speed \(speed)")
    }

    /// `TEXTWIPE <name> [direction] SPEED <n>` — how text arrives on an already-shown
    /// page, which is a separate transition from the page wipe.
    public static func textWipe(
        _ name: String, direction: String? = nil, speed: Int
    ) -> TitlerCommand {
        var arguments: [TitlerCommand.Argument] = [.word(name)]
        if let direction { arguments.append(.word(direction)) }
        arguments.append(.word("SPEED"))
        arguments.append(.number(Double(clamp(speed, to: speedRange))))
        return TitlerCommand(
            verb: "TEXTWIPE", arguments: arguments,
            explanation: "bring text on with \(name) at speed \(speed)")
    }

    /// `FONT <face>.font <size>` — the face and size of everything drawn after it.
    ///
    /// THIS IS SCALA'S TEXT SCALE. There is no separate scale command for text: type
    /// is resized by re-selecting the font at a different size, which is how a
    /// bitmap-font machine does it.
    public static func font(_ face: String, size: Int) -> TitlerCommand {
        let clamped = clamp(size, to: fontSizeRange)
        return TitlerCommand(
            verb: "FONT",
            arguments: [.word("\(face).font"), .number(Double(clamped))],
            explanation: "set type to \(face) at \(clamped)pt")
    }

    /// `GOTO "<event>"` — jump to a named page.
    ///
    /// Scala's pages are `EVENT`s with names, so "go to page 3" is really "go to the
    /// event called this". The panel's page control therefore picks from names the
    /// script defines rather than counting.
    public static func goTo(event: String) -> TitlerCommand {
        TitlerCommand(
            verb: "GOTO", arguments: [.text(event)],
            explanation: "jump to the page called \"\(event)\"")
    }

    /// `PALETTE <hex> <hex> <hex> <hex>` — the screen palette, as RGB hex.
    ///
    /// Real colour, not an index into someone else's table. The disc writes them as
    /// three-digit hex (`0f7`, `c07`) and occasionally six (`06cf91`); three is what
    /// the Amiga's 4 bits per gun actually holds, so that is what is emitted.
    public static func palette(_ colours: [ScalaColour]) -> TitlerCommand {
        TitlerCommand(
            verb: "PALETTE",
            arguments: colours.map { .word($0.amigaHex) },
            explanation: "set the palette to \(colours.map(\.amigaHex).joined(separator: " "))")
    }

    /// `COLOR <index> ...` — which palette entries the text's fill, shadow and outline
    /// use.
    ///
    /// The disc's lines run to fifteen numbers. Only the first few are ever non-zero
    /// in practice, and the rest are trailing defaults, so this emits the leading ones
    /// and lets Scala default the tail.
    public static func colour(fill: Int, shadow: Int = 0, outline: Int = 0) -> TitlerCommand {
        TitlerCommand(
            verb: "COLOR",
            arguments: [fill, shadow, outline].map { .number(Double(clamp($0, to: 0...31))) },
            explanation: "text fill \(fill), shadow \(shadow), outline \(outline)")
    }

    /// `BRUSH <x> <y> "<file>" size <w> <h>` — place a graphic, at a chosen size.
    ///
    /// THIS IS SCALA'S SCALE. A brush is drawn into a rectangle you specify, so
    /// scaling a graphic means restating its size — which makes a size fader a real
    /// scale control rather than a metaphor.
    public static func brush(
        x: Int, y: Int, file: String, width: Int, height: Int
    ) -> TitlerCommand {
        TitlerCommand(
            verb: "BRUSH",
            arguments: [
                .number(Double(x)), .number(Double(y)), .text(file),
                .word("size"), .number(Double(width)), .number(Double(height))
            ],
            explanation: "place \(file) at \(x), \(y) scaled to \(width)×\(height)")
    }

    /// `ATTRIBUTES <word> ...` — how text is drawn: antialiased, shadowed, aligned.
    public static func attributes(_ words: [String]) -> TitlerCommand {
        TitlerCommand(
            verb: "ATTRIBUTES", arguments: words.map { .word($0) },
            explanation: "draw text \(words.joined(separator: ", "))")
    }

    /// The mutually exclusive text alignments.
    ///
    /// Counted from Scala's own scripts: center 148, left 51, right 3. The order below
    /// is that order, because what its authors reached for most is a better guide to
    /// what matters than what reads well in a list.
    public static let alignments = ["left", "center", "right"]

    /// The mutually exclusive ways of edging type. `none` is a real choice, not an
    /// absence: Scala's own scripts use it three times.
    public static let edgeStyles = ["none", "shadow", "edge", "bevel"]

    /// `BOX <x1> <y1> <x2> <y2>` - a filled rectangle.
    ///
    /// The lower-third bar. Scala draws it in the current background colour, so the
    /// back-colour fader and this one are the same control seen from two sides.
    public static func box(x1: Int, y1: Int, x2: Int, y2: Int) -> TitlerCommand {
        TitlerCommand(
            verb: "BOX",
            arguments: [x1, y1, x2, y2].map { .number(Double($0)) },
            explanation: "fill \(x1), \(y1) to \(x2), \(y2)")
    }

    /// `PICTURE <file>` - the background behind everything.
    ///
    /// Switching backgrounds is the loudest single thing this software can do, and it
    /// is one command, which makes it the obvious one to put on the beat.
    public static func picture(_ file: String) -> TitlerCommand {
        TitlerCommand(
            verb: "PICTURE", arguments: [.text(file)],
            explanation: "background \((file as NSString).lastPathComponent)")
    }

    /// `CYCLE on|off` — Amiga colour cycling.
    ///
    /// Included because it is the single most period-correct effect the machine has
    /// and it costs one word. Cycling a palette on the beat is a thing this app should
    /// obviously be able to do.
    public static func cycle(_ on: Bool) -> TitlerCommand {
        TitlerCommand(
            verb: "CYCLE", arguments: [.word(on ? "on" : "off")],
            explanation: on ? "start colour cycling" : "stop colour cycling")
    }

    /// `MARGINS on <left> <right>` — the column text wraps inside.
    public static func margins(left: Int, right: Int) -> TitlerCommand {
        TitlerCommand(
            verb: "MARGINS",
            arguments: [.word("on"), .number(Double(left)), .number(Double(right))],
            explanation: "wrap text between \(left) and \(right)")
    }

    /// `PAUSE <seconds>` — hold the page. `-1` holds until a click.
    public static func pause(seconds: Double) -> TitlerCommand {
        TitlerCommand(
            verb: "PAUSE", arguments: [.number(seconds)],
            explanation: seconds < 0 ? "hold until clicked" : "hold for \(seconds)s")
    }

    /// `SHOW` — display the page that has been prepared.
    ///
    /// Scala builds a page off-screen and reveals it on `SHOW`, which is why the panel
    /// can change several things at once and have them appear together instead of
    /// crawling on one at a time.
    public static func show() -> TitlerCommand {
        TitlerCommand(verb: "SHOW", arguments: [], explanation: "reveal the prepared page")
    }

    /// `BLANK <w> <h> <depth> [lace] [hires] <colour>` — the screen mode.
    ///
    /// Worth having because this app's whole output path is 480i: telling Scala to run
    /// 640×512 interlaced is what makes its picture match, rather than scaling a
    /// non-interlaced screen up afterwards and losing the look.
    public static func screen(
        width: Int = 640, height: Int = 512, depth: Int = 3,
        interlaced: Bool = true, hires: Bool = true, background: Int = 0
    ) -> TitlerCommand {
        var arguments: [TitlerCommand.Argument] = [
            .number(Double(width)), .number(Double(height)), .number(Double(depth))
        ]
        if interlaced { arguments.append(.word("lace")) }
        if hires { arguments.append(.word("hires")) }
        arguments.append(.number(Double(background)))
        return TitlerCommand(
            verb: "BLANK", arguments: arguments,
            explanation: "\(width)×\(height)"
                + (interlaced ? " interlaced" : "") + ", \(depth) bitplanes")
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A colour on the Amiga's terms.
///
/// The Amiga's palette registers hold 4 bits per gun, so a colour is one hex digit
/// each and there are 4096 of them. Stored as 0...1 so a fader reaches it, and
/// QUANTISED ON THE WAY OUT rather than on the way in — a fader that visibly snaps
/// while you drag it feels broken, even when the snapping is correct.
/// A typeface on the machine, and the sizes it actually exists at.
///
/// Both halves matter. A face with no size list is a face that cannot be used safely,
/// because asking for a size it does not have drops Scala's screen — see
/// `AmigaSystemInstaller.fonts(in:fileManager:)` for the evidence.
public struct ScalaFont: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Ascending, and never empty.
    public let sizes: [Int]

    public init(name: String, sizes: [Int]) {
        self.name = name
        self.sizes = sizes
    }

    /// The size on this face closest to the one asked for.
    ///
    /// Used when the face changes under a chosen size: moving from Franklin 72 to Didot
    /// has to land on 56, because Didot has no 72 and asking for one puts a boot prompt
    /// on the programme output.
    public func nearestSize(to wanted: Int) -> Int {
        sizes.min(by: { abs($0 - wanted) < abs($1 - wanted) }) ?? sizes[0]
    }
}

public struct ScalaColour: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The three-digit hex the disc's `PALETTE` lines use.
    public var amigaHex: String {
        func digit(_ value: Double) -> String {
            let stepped = Int((NormalisedSweep.clamp(value) * 15).rounded())
            return String(stepped, radix: 16)
        }
        return digit(red) + digit(green) + digit(blue)
    }

    /// A colour picked by sweeping one 0...1 value around the hue circle.
    ///
    /// The point of a one-knob colour: a fader has one dimension and colour has three,
    /// so the useful reduction is hue at full saturation — which is also what a
    /// 12-bit palette shows off best.
    /// A mix of two colours, for filling palette entries nobody chose.
    ///
    /// The screen has eight entries and the panel names two of them. The rest used to
    /// be left holding whatever was in them; a defined colour nobody asked for is at
    /// least predictable, and a ramp between the two chosen ones is the least
    /// surprising thing to put there.
    public func blended(with other: ScalaColour, amount: Double) -> ScalaColour {
        let t = min(max(amount, 0), 1)
        return ScalaColour(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t)
    }

    public static func hue(_ value: Double) -> ScalaColour {
        let hue = NormalisedSweep.clamp(value) * 6
        let sector = Int(hue) % 6
        let rising = hue - Double(Int(hue))
        let falling = 1 - rising
        switch sector {
        case 0: return ScalaColour(red: 1, green: rising, blue: 0)
        case 1: return ScalaColour(red: falling, green: 1, blue: 0)
        case 2: return ScalaColour(red: 0, green: 1, blue: rising)
        case 3: return ScalaColour(red: 0, green: falling, blue: 1)
        case 4: return ScalaColour(red: rising, green: 0, blue: 1)
        default: return ScalaColour(red: 1, green: 0, blue: falling)
        }
    }

    public static let black = ScalaColour(red: 0, green: 0, blue: 0)
    public static let white = ScalaColour(red: 1, green: 1, blue: 1)
}
