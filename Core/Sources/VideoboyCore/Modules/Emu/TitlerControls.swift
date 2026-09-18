//
//  TitlerControls.swift — the translation layer.
//
//  Purpose : A fader on this side; a real command to the software's script port on the
//            other. This is the part that makes a 1990s titler playable from a 2026
//            control surface — and the part that has to be honest, because a fader
//            that moves and changes nothing is worse than no fader.
//  Inputs  : values 0...1, so ANYTHING that already produces one can drive it — a
//            fader, a MIDI CC, an LFO, a fader sweep on the beat. None of those can
//            type; all of them can move a number.
//  Outputs : `TitlerCommand`s in the program's own dialect.
//  Connects: ScalaLingo (the dialect), AmigaCommandBridge (which carries the lines
//            in), the EMU panel, EmulatedTitlerNode.
//  Extend  : A SECOND PROGRAM IS A SECOND PANEL TYPE next to `ScalaTitlerPanel`,
//            built on its own dialect file. This file's generic half — `TitlerControl`
//            and `TitlerFunction` — is shared; the half that knows what `speed 1`
//            means is not.
//
//  ── WHY THE PANEL HOLDS STATE ───────────────────────────────────────────────────
//
//  The obvious design is a pure function: one fader in, one command out. It does not
//  survive contact with the real vocabulary. Scala's line is
//
//      WIPE curtain south SPEED 10
//
//  — one command carrying THREE of our faders. Move the speed fader and the whole line
//  has to be reissued, which means knowing which wipe and which direction are
//  currently chosen. The same is true of `FONT Franklin.font 44` (two faders) and
//  `TEXT 20 40 "..."` (two faders and a text box).
//
//  So the panel holds the native values and each fader rewrites its part of them. That
//  is not incidental complexity — it is the shape of the software being driven, and a
//  stateless design would simply have emitted broken lines.
//

import Foundation

/// What a control actually reaches inside the running software.
///
/// Named for the SOFTWARE'S function rather than for the widget. `fontSize` is not
/// "the size slider", it is Scala's only means of scaling type — and naming it that
/// way is what keeps a control from being invented.
public enum TitlerFunction: String, Equatable, Codable, Sendable, CaseIterable {
    /// Which page wipe is used: `WIPE <name> …`
    case wipe
    /// The wipe's direction: `WIPE … south …`
    case wipeDirection
    /// How long the wipe takes: `WIPE … SPEED <n>`
    case wipeSpeed
    /// How text arrives on an already-shown page: `TEXTWIPE <name> …`
    case textWipe
    /// The typeface: `FONT <face>.font …`
    case fontFace
    /// The type size — SCALA'S ONLY TEXT SCALE: `FONT … <size>`
    case fontSize
    /// Text colour, through the screen palette: `PALETTE …`
    case textColour
    /// Background colour, likewise.
    case backgroundColour
    /// How big a placed graphic is drawn — SCALA'S GRAPHIC SCALE:
    /// `BRUSH … size <w> <h>`
    case brushScale
    /// Where the text sits across the screen: `TEXT <x> … `
    case textX
    /// And down it: `TEXT … <y> …`
    case textY
    /// Alignment: `ATTRIBUTES center`
    case alignment
    /// Amiga colour cycling: `CYCLE on|off`
    case colourCycle
    /// How long a page holds: `PAUSE <seconds>`
    case hold
    /// Jump to a named page: `GOTO "<event>"`
    case page
    /// How type is edged: `ATTRIBUTES shadow|edge|bevel`
    case decoration
    /// Italics: `ATTRIBUTES italics`
    case italic
    /// Which background picture is behind everything: `PICTURE <file>`
    case backdrop
    /// A filled bar behind the text: `BOX x1 y1 x2 y2`
    case box
}

extension TitlerFunction {
    /// The stable param code for this function.
    public var code: ParamCode {
        switch self {
        case .wipe: .emuWipe
        case .wipeDirection: .emuWipeDirection
        case .wipeSpeed: .emuWipeSpeed
        case .textWipe: .emuTextWipe
        case .fontFace: .emuFontFace
        case .fontSize: .emuFontSize
        case .textColour: .emuTextColour
        case .backgroundColour: .emuBackgroundColour
        case .brushScale: .emuBrushScale
        case .textX: .emuTextX
        case .textY: .emuTextY
        case .alignment: .emuAlignment
        case .colourCycle: .emuColourCycle
        case .hold: .emuHold
        case .page: .emuPage
        case .decoration: .emuDecoration
        case .italic: .emuItalic
        case .backdrop: .emuBackdrop
        case .box: .emuBox
        }
    }

    /// The function a code addresses, or nil when the code is not an EMU one.
    public static func forCode(_ code: ParamCode) -> TitlerFunction? {
        allCases.first { $0.code == code }
    }
}

/// One control on the titler panel.
public struct TitlerControl: Equatable, Sendable, Identifiable {
    public var id: String { name }

    /// The label on the fader. Short, because it sits under a small picture.
    public let name: String
    /// What it does, for the tooltip — in terms of the SOFTWARE, not the widget.
    public let explanation: String
    /// The function inside the software that it reaches.
    public let function: TitlerFunction
    /// What KIND of control this is, so a view cannot invent the wrong widget.
    ///
    /// ── WHY THE PANEL DECLARES THIS AND THE VIEW OBEYS ──────────────────────────
    ///
    /// Every one of these was a fader. Choosing one of fifty-one wipes meant dragging a
    /// slider until the readout happened to say the name you wanted, and choosing a
    /// typeface meant the same. That is not a control, it is a guessing game — and for
    /// the font it was a dangerous one, because the sizes in between the real ones drop
    /// Scala's screen.
    ///
    /// A list is a list. It gets a menu. Only quantities get faders.
    public enum Shape: Equatable, Sendable {
        /// One of several named things: a menu.
        case list
        /// On or off: a switch.
        case toggle
        /// A quantity with meaningful in-between values: a fader.
        case continuous
        /// A colour: a colour well.
        case colour
    }

    /// Which widget this control needs.
    public var shape: Shape {
        switch function {
        case .wipe, .wipeDirection, .textWipe, .fontFace, .fontSize,
             .alignment, .decoration, .backdrop, .page:
            return .list
        case .colourCycle, .italic:
            return .toggle
        case .textColour, .backgroundColour:
            return .colour
        case .wipeSpeed, .brushScale, .textX, .textY, .hold, .box:
            return .continuous
        }
    }

    /// Whether this one is a switch rather than a fader.
    public var isToggle: Bool { shape == .toggle }

    /// The stable param code this control lives at.
    ///
    /// Stable because it is what a MIDI mapping and a saved template store. Every EMU
    /// control has one, which is what makes them shift-selectable, automatable and
    /// beat-syncable by the same machinery as every other fader in the app — none of
    /// which had to learn anything about emulators.
    public var code: ParamCode { function.code }

    public init(name: String, explanation: String, function: TitlerFunction) {
        self.name = name
        self.explanation = explanation
        self.function = function
    }
}

/// The native values a Scala panel is currently holding.
///
/// Native, not normalised: this is the state of the emulated program as far as we know
/// it, so it is kept in Scala's own units. Converting at the edge rather than storing
/// 0...1 means the readout under a fader can say "Franklin 44pt" instead of "0.31".
public struct ScalaPanelState: Equatable, Sendable {

    /// Index into `ScalaLingo.wipes`.
    public var wipeIndex: Int = 1          // "fade"
    /// Index into `ScalaLingo.directions`, or nil for a wipe with no direction.
    public var directionIndex: Int? = nil
    public var wipeSpeed: Int = 5          // the disc's most common speed
    public var textWipeIndex: Int = 6      // "dump" — text appears at once
    /// Index into `ScalaLingo.fonts`.
    public var fontIndex: Int = 4          // "Franklin", the ARexx example's face
    public var fontSize: Int = 44
    public var textColour: ScalaColour = .white
    public var backgroundColour: ScalaColour = .black
    /// A placed graphic's width as a fraction of the screen. ZERO means no graphic.
    ///
    /// Zero by default, and zero is a real setting rather than a very small one — the
    /// same idiom the bar uses. A drive is scanned for symbols so that the scale control
    /// has something to scale, and for a while that meant every page carried the first
    /// symbol on the disc: a full-screen arrow, over the title, that nobody had asked
    /// for and no control would remove.
    public var brushScale: Double = 0
    public var textX: Int = 20
    public var textY: Int = 40
    /// Index into `ScalaLingo.alignments`.
    public var alignmentIndex: Int = 0
    public var isCycling: Bool = false
    /// Seconds a page holds. Negative means "until clicked".
    public var hold: Double = -1
    /// Index into whatever page names the loaded script defines.
    public var pageIndex: Int = 0

    /// The line of text being titled.
    ///
    /// Held here rather than passed in because every control that moves the text has to
    /// reissue the whole `TEXT x y "..."` line, and a line missing its string draws
    /// nothing.
    public var text: String = "VIDEOBOY"

    /// The second line, empty when there is only one.
    ///
    /// Scala really does carry several lines on a page — see
    /// selfqa/out/emu-probe/13-two-texts-on-one-page.png — and a titler that can only
    /// ever show one is not much of a titler: a lower third is a name and a role.
    /// The second line sits a line's height below the first rather than having its own
    /// position, because two independent XY pairs is four faders to keep in agreement
    /// and nobody wants that mid-set.
    public var textTwo: String = ""

    /// The graphic the scale control scales, when one has been chosen.
    public var brushFile: String? = nil

    /// Index into `ScalaLingo.edgeStyles`.
    public var edgeIndex: Int = 1          // "shadow", by far the most used on the disc
    public var isItalic: Bool = false
    /// Index into the backdrops the panel knows about.
    public var backdropIndex: Int = 0
    /// Whether a backdrop has been chosen at all.
    ///
    /// `backdropIndex` has no "none" value — index 0 is a real picture — so without this
    /// every repaint would put the first backdrop on the screen whether or not anyone
    /// asked for one.
    public var hasBackdrop: Bool = false
    /// How tall the bar behind the text is, as a fraction of the screen. 0 is off.
    public var boxHeight: Double = 0

    public init() {}
}

/// The screen the emulated Amiga is set to.
///
/// NTSC by default, because this app's output chain is 480i NTSC throughout and a PAL
/// screen would be letterboxed or cropped on the way out. The disc's own scripts are
/// authored for PAL 640×512, so page layouts from it sit slightly low on an NTSC
/// screen — a real trade, taken deliberately in favour of the output path.
public struct ScalaScreen: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isInterlaced: Bool

    public static let ntsc = ScalaScreen(width: 640, height: 400, isInterlaced: true)
    public static let pal = ScalaScreen(width: 640, height: 512, isInterlaced: true)

    public init(width: Int, height: Int, isInterlaced: Bool) {
        self.width = width
        self.height = height
        self.isInterlaced = isInterlaced
    }
}

/// Scala MM300's panel: 0...1 in, real Lingo out.
///
/// The bellwether. Every later program gets one of these — same outside, different
/// dialect inside.
public final class ScalaTitlerPanel {

    public private(set) var state = ScalaPanelState()
    public var screen: ScalaScreen = .ntsc

    /// The page names the loaded script defines, in order.
    ///
    /// Empty until a script has been read, and the page control reports itself
    /// unavailable rather than guessing — Scala's pages are named `EVENT`s, so there is
    /// no "page 3" to jump to until something says what page 3 is called.
    public var pageNames: [String] = []

    /// Background pictures this machine can reach, by Amiga path.
    ///
    /// Filled from the disc at setup. Empty until then, and the control says so rather
    /// than offering a fader that picks between nothing.
    public var backdrops: [String] = []

    /// The typefaces on the machine, with the sizes each actually has.
    ///
    /// Empty until a drive has been read. `ScalaLingo.fonts` is the fallback list of
    /// NAMES only — it cannot say which sizes exist, which is why a scanned catalogue
    /// replaces it as soon as there is one.
    public var fontCatalogue: [ScalaFont] = [] {
        didSet { clampFontToCatalogue() }
    }

    /// The face currently chosen, as the catalogue knows it.
    public var currentFace: ScalaFont? {
        guard !fontCatalogue.isEmpty else { return nil }
        return fontCatalogue[min(state.fontIndex, fontCatalogue.count - 1)]
    }

    /// Forces the chosen size to be one the chosen face actually has.
    ///
    /// Called whenever either changes. Asking Scala for a size a bitmap face does not
    /// have does not degrade — it drops the screen and the machine's output reverts to
    /// the AmigaDOS console, which on air is a boot prompt on PROGRAM.
    private func clampFontToCatalogue() {
        guard let face = currentFace else { return }
        if !face.sizes.contains(state.fontSize) {
            state.fontSize = face.nearestSize(to: state.fontSize)
        }
    }

    public init() {}

    /// The controls this panel offers.
    ///
    /// Built from what Scala CAN DO, in the order a person reaches for them: pick the
    /// transition, set its timing, choose the type, colour it, place it.
    public static let controls: [TitlerControl] = [
        TitlerControl(
            name: "WIPE",
            explanation: "Which of Scala's 51 transitions takes the page. The list is "
                + "read off the disc's own scripts, so everything here is one Scala "
                + "really has — including the odd ones like NUCLEAR and ANTS.",
            function: .wipe),
        TitlerControl(
            name: "DIR",
            explanation: "The direction the wipe travels. Scala ignores a direction a "
                + "wipe cannot use, so this is safe to sweep across any of them.",
            function: .wipeDirection),
        TitlerControl(
            name: "SPEED",
            explanation: "How long the wipe takes. Scala counts backwards — 1 is "
                + "instant and 16 is slow — so this fader is inverted to read the way "
                + "a speed control should.",
            function: .wipeSpeed),
        TitlerControl(
            name: "TXT WIPE",
            explanation: "How the text arrives on a page that is already up. A "
                + "separate transition from the page wipe, which is what lets a line "
                + "change without the whole screen moving.",
            function: .textWipe),
        TitlerControl(
            name: "FONT",
            explanation: "The typeface, from the seventeen Scala's own scripts title "
                + "with. All of them are installed on the disc.",
            function: .fontFace),
        TitlerControl(
            name: "SCALE",
            explanation: "Type size, 12 to 114 point. THIS IS SCALA'S TEXT SCALE — it "
                + "has no separate scale command, because a bitmap-font machine resizes "
                + "type by re-selecting the font.",
            function: .fontSize),
        TitlerControl(
            name: "TEXT COL",
            explanation: "Text colour, swept around the hue circle and quantised to the "
                + "Amiga's 4 bits per gun on the way out.",
            function: .textColour),
        TitlerControl(
            name: "BACK COL",
            explanation: "Background colour, likewise. Black is the genlock key, so "
                + "leaving it at the bottom of the fader is what makes the titler "
                + "overlay rather than cover.",
            function: .backgroundColour),
        TitlerControl(
            name: "GFX SCALE",
            explanation: "How large a placed graphic is drawn. Scala scales a brush by "
                + "being told the rectangle to draw it into, so this is a real scale "
                + "control. Needs a graphic chosen first.",
            function: .brushScale),
        TitlerControl(
            name: "X",
            explanation: "Where the text sits across the screen. Scala has no named "
                + "text fields — it has a screen and coordinates on it.",
            function: .textX),
        TitlerControl(
            name: "Y",
            explanation: "And where it sits down the screen.",
            function: .textY),
        TitlerControl(
            name: "ALIGN",
            explanation: "Left, centre or right, through Scala's text attributes.",
            function: .alignment),
        TitlerControl(
            name: "HOLD",
            explanation: "How long a page stays up before the script moves on. At the "
                + "bottom it holds until clicked.",
            function: .hold),
        TitlerControl(
            name: "PAGE",
            explanation: "Jump to a named page. Scala's pages are named EVENTs, so this "
                + "stays unavailable until a script has been read and its page names "
                + "are known.",
            function: .page),
        TitlerControl(
            name: "EDGE",
            explanation: "How type is edged — shadow, outline or bevel. These are "
                + "Scala's own attribute words, and shadow is what its authors used "
                + "nearly two hundred times in their own scripts.",
            function: .decoration),
        TitlerControl(
            name: "ITALIC",
            explanation: "Slants the type, through Scala's italics attribute.",
            function: .italic),
        TitlerControl(
            name: "BACKDROP",
            explanation: "Which background picture is behind everything. Switching "
                + "backgrounds is the loudest single thing this software does and it "
                + "is ONE command, which makes it the obvious thing to put on the beat. "
                + "Needs the disc's Backgrounds drawer.",
            function: .backdrop),
        TitlerControl(
            name: "BAR",
            explanation: "A filled bar behind the text, for a lower third. Scala draws "
                + "it in the background colour, so this and BACK COL are one control "
                + "seen from two sides. At the bottom of the fader there is no bar.",
            function: .box),
        TitlerControl(
            name: "CYCLE",
            explanation: "Amiga colour cycling — the palette rotates in hardware. The "
                + "most period-correct effect the machine has, and it costs one word.",
            function: .colourCycle)
    ]

    /// Whether a control can do anything right now, and why not when it cannot.
    ///
    /// A control with nothing behind it is shown DISABLED rather than hidden, per the
    /// house rule, and it says what would make it work.
    public func unavailableReason(for function: TitlerFunction) -> String? {
        switch function {
        case .page:
            return pageNames.isEmpty
                ? "No script loaded — Scala's pages are named, so there is nothing to jump to yet"
                : nil
        case .brushScale:
            return state.brushFile == nil
                ? "No graphic chosen — pick one from the disc's Symbols or Backgrounds drawer"
                : nil
        case .backdrop:
            return backdrops.isEmpty
                ? "No backgrounds found — they come from the disc's Scala/Backgrounds drawer"
                : nil
        case .fontSize:
            // An Amiga font exists at fixed sizes and nowhere between them, and the set
            // is different for every face. Until a drive has been read there is no way
            // to know which sizes are safe to ask for — and asking for an unsafe one
            // drops Scala's screen, so this stays shut rather than guessing.
            return faceSizes.isEmpty
                ? "No drive read yet — an Amiga font only exists at fixed sizes, and they "
                    + "have to be read off the disc before any of them is safe to ask for"
                : nil
        default:
            return nil
        }
    }

    /// Moves a control and returns the script lines that produces.
    ///
    /// Returns an ARRAY because one fader genuinely can be several lines: changing the
    /// font size reissues `FONT` and then the `TEXT` that uses it, and ends with `SHOW`
    /// so the change appears instead of sitting on an off-screen page.
    @discardableResult
    public func set(_ function: TitlerFunction, to value: Double) -> [TitlerCommand] {
        guard unavailableReason(for: function) == nil else {
            Log.warn(.titler, "\(function.rawValue) is unavailable: "
                + (unavailableReason(for: function) ?? ""))
            return []
        }
        let clamped = NormalisedSweep.clamp(value)

        switch function {
        case .wipe:
            state.wipeIndex = NormalisedSweep.index(clamped, count: ScalaLingo.wipes.count)

        case .wipeDirection:
            // The bottom of the fader means NO direction, which is a real setting —
            // most wipes take none, and forcing one on them is how you get a `fade`
            // that Scala quietly refuses.
            let count = ScalaLingo.directions.count + 1
            let index = NormalisedSweep.index(clamped, count: count)
            state.directionIndex = index == 0 ? nil : index - 1

        case .wipeSpeed:
            // Inverted: Scala's 1 is the fast one. A fader labelled SPEED that gets
            // slower as it goes up is the kind of small wrongness that makes a panel
            // untrustworthy.
            state.wipeSpeed = invertedSpeed(clamped)

        case .textWipe:
            state.textWipeIndex = NormalisedSweep.index(clamped, count: ScalaLingo.wipes.count)

        case .fontFace:
            state.fontIndex = NormalisedSweep.index(clamped, count: faceCount)
            // The new face almost certainly does not have the old face's size. Franklin
            // has 72 and Didot does not; asking Didot for 72 drops Scala's screen.
            clampFontToCatalogue()

        case .fontSize:
            // Stepped through the sizes this FACE has, not swept over a range. There is
            // no such thing as an in-between size for a bitmap font, and asking for one
            // is how the machine's output ends up showing a boot prompt.
            if let face = currentFace {
                state.fontSize = face.sizes[NormalisedSweep.index(clamped, count: face.sizes.count)]
            } else {
                state.fontSize = scaled(clamped, into: ScalaLingo.fontSizeRange)
            }

        case .textColour:
            state.textColour = .hue(clamped)

        case .backgroundColour:
            state.backgroundColour = .hue(clamped)

        case .brushScale:
            // The bottom of the control is "no graphic", so a page carries one only when
            // it has been asked for.
            state.brushScale = clamped < 0.02 ? 0 : 0.1 + clamped * 1.9

        case .textX:
            state.textX = scaled(clamped, into: 0...(screen.width - 1))

        case .textY:
            state.textY = scaled(clamped, into: 0...(screen.height - 1))

        case .alignment:
            state.alignmentIndex =
                NormalisedSweep.index(clamped, count: ScalaLingo.alignments.count)
            // Move the anchor with it. Scala aligns text AROUND the X it is given, so
            // picking "centre" while X sits at the left margin centres the line on the
            // left margin and half of it falls off the screen — which is exactly what
            // happened in selfqa/out/emu-probe/25-panel-backdrop-menu.png. Every titler
            // moves the anchor when you press an align button; X is still free to be
            // dragged afterwards.
            state.textX = anchorX(forAlignment: state.alignmentIndex)

        case .decoration:
            state.edgeIndex = NormalisedSweep.index(clamped, count: ScalaLingo.edgeStyles.count)

        case .italic:
            state.isItalic = clamped >= 0.5

        case .backdrop:
            guard !backdrops.isEmpty else { return [] }
            state.backdropIndex = NormalisedSweep.index(clamped, count: backdrops.count)
            state.hasBackdrop = true

        case .box:
            state.boxHeight = clamped

        // ── The three that are NOT page paint ────────────────────────────────────
        //
        // These change what the machine DOES rather than what the page looks like, so
        // they go on their own and deliberately do not force a repaint. Sending GOTO
        // wrapped in a fresh page would throw away the page it just went to.
        case .colourCycle:
            state.isCycling = clamped >= 0.5
            return [ScalaLingo.cycle(state.isCycling)]

        case .hold:
            // The very bottom is "until clicked", which is Scala's -1 and the setting a
            // live operator wants most of the time.
            state.hold = clamped < 0.02 ? -1 : clamped * 30
            return [ScalaLingo.pause(seconds: state.hold)]

        case .page:
            state.pageIndex = NormalisedSweep.index(clamped, count: pageNames.count)
            return [ScalaLingo.goTo(event: pageNames[state.pageIndex])]
        }

        return page()
    }

    /// Puts the page up WITH the chosen wipe. The deliberate act, as opposed to the
    /// instant redraws every edit performs.
    public func take() -> [TitlerCommand] {
        page(transition: true)
    }

    /// Sets the line of text and returns the lines that puts it on screen.
    public func setText(_ text: String) -> [TitlerCommand] {
        state.text = text
        return page()
    }

    /// Sets one of the two lines.
    public func setText(_ text: String, line: Int) -> [TitlerCommand] {
        if line == 0 { state.text = text } else { state.textTwo = text }
        return page()
    }

    /// Chooses the graphic the scale control scales.
    public func setBrush(file: String?) {
        state.brushFile = file
    }

    /// The choices a list control offers, in the order a menu should show them.
    ///
    /// Read from the machine wherever the machine knows: the faces and their sizes come
    /// off the drive, the backdrops out of the Backgrounds drawer, the page names out of
    /// the scripts. Hard-coding any of them is how the panel ends up offering a font
    /// that is not installed.
    public func options(for function: TitlerFunction) -> [String] {
        switch function {
        case .wipe, .textWipe: return ScalaLingo.wipes
        case .wipeDirection: return ["(none)"] + ScalaLingo.directions
        case .fontFace:
            return fontCatalogue.isEmpty ? ScalaLingo.fonts : fontCatalogue.map(\.name)
        case .fontSize:
            let sizes = faceSizes
            return sizes.isEmpty ? [] : sizes.map { "\($0)pt" }
        case .alignment: return ScalaLingo.alignments
        case .decoration: return ScalaLingo.edgeStyles
        case .backdrop: return backdrops.map(Self.leafName)
        case .page: return pageNames
        default: return []
        }
    }

    /// Which option is currently chosen, as an index into `options(for:)`.
    public func selectedOption(for function: TitlerFunction) -> Int {
        switch function {
        case .wipe: return state.wipeIndex
        case .textWipe: return state.textWipeIndex
        case .wipeDirection: return state.directionIndex.map { $0 + 1 } ?? 0
        case .fontFace: return min(state.fontIndex, max(faceCount - 1, 0))
        case .fontSize: return faceSizes.firstIndex(of: state.fontSize) ?? 0
        case .alignment: return state.alignmentIndex
        case .decoration: return state.edgeIndex
        case .backdrop: return state.hasBackdrop ? state.backdropIndex : 0
        case .page: return state.pageIndex
        default: return 0
        }
    }

    /// Chooses option `index` of a list control, and returns what that sends.
    ///
    /// Goes through `set` rather than round it, so a menu, a MIDI knob and an LFO all
    /// travel the same path and cannot disagree about what a value means.
    public func choose(_ function: TitlerFunction, option index: Int) -> [TitlerCommand] {
        let count = options(for: function).count
        guard count > 0 else { return [] }
        return set(function, to: NormalisedSweep.value(forIndex: index, count: count))
    }

    /// The last component of an Amiga path, for a menu that has to fit in a panel.
    private static func leafName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Whether a toggle control is currently on.
    public func isOn(_ function: TitlerFunction) -> Bool {
        switch function {
        case .colourCycle: return state.isCycling
        case .italic: return state.isItalic
        default: return false
        }
    }

    /// The colour a colour control currently holds, for the well that shows it.
    public func colour(for function: TitlerFunction) -> ScalaColour? {
        switch function {
        case .textColour: return state.textColour
        case .backgroundColour: return state.backgroundColour
        default: return nil
        }
    }

    /// What a control currently reads, in Scala's own units, for the readout under it.
    ///
    /// In native units on purpose: "Franklin 44pt" tells an operator something, "0.31"
    /// does not.
    public func readout(for function: TitlerFunction) -> String {
        switch function {
        case .wipe: return ScalaLingo.wipes[state.wipeIndex].uppercased()
        case .wipeDirection:
            return state.directionIndex.map { ScalaLingo.directions[$0].uppercased() } ?? "—"
        case .wipeSpeed: return "\(state.wipeSpeed)"
        case .textWipe: return ScalaLingo.wipes[state.textWipeIndex].uppercased()
        case .fontFace: return faceName
        case .fontSize: return "\(state.fontSize)pt"
        case .textColour: return "#" + state.textColour.amigaHex
        case .backgroundColour: return "#" + state.backgroundColour.amigaHex
        case .brushScale:
            return state.brushScale <= 0 ? "OFF" : "\(Int(state.brushScale * 100))%"
        case .textX: return "\(state.textX)"
        case .textY: return "\(state.textY)"
        case .alignment: return ScalaLingo.alignments[state.alignmentIndex].uppercased()
        case .colourCycle: return state.isCycling ? "ON" : "OFF"
        case .hold: return state.hold < 0 ? "CLICK" : String(format: "%.1fs", state.hold)
        case .page:
            guard state.pageIndex < pageNames.count else { return "—" }
            return pageNames[state.pageIndex]
        case .decoration: return ScalaLingo.edgeStyles[state.edgeIndex].uppercased()
        case .italic: return state.isItalic ? "ON" : "OFF"
        case .backdrop:
            guard state.backdropIndex < backdrops.count else { return "—" }
            return (backdrops[state.backdropIndex] as NSString).lastPathComponent
        case .box: return state.boxHeight < 0.02 ? "OFF" : "\(Int(state.boxHeight * 100))%"
        }
    }

    /// The whole panel as script, for setting a machine to a known state.
    ///
    /// Used when a program has just booted: the emulated Amiga has no idea what the
    /// faders are showing, so everything is sent once and the two agree from then on.
    public func fullState() -> [TitlerCommand] { page() }

    /// Everything the current state describes, as ONE page.
    ///
    /// ── WHY EVERY CHANGE SENDS ALL OF THIS ──────────────────────────────────────
    ///
    /// Because Scala draws PAGES, not pixels. `SCREEN` begins a new page, the drawing
    /// commands paint it while it is off-screen, and `SHOW` reveals it. A command sent
    /// on its own — `TEXT`, then `SHOW` — paints a page that has ALREADY been shown,
    /// which is invisible. Scala accepts it and returns zero, so nothing anywhere
    /// reports a problem.
    ///
    /// That is exactly what happened: every fader and the text field sent a small
    /// fragment ending in `SHOW`, every command was accepted, and the screen never
    /// changed once after the first page. The panel looked completely dead. Sending the
    /// whole page is not wasteful here — it is the unit Scala actually works in.
    ///
    /// The cost is real but bounded: the bridge coalesces at 20Hz, last-wins per verb,
    /// so dragging a fader sends at most one page per 50ms rather than one per frame.
    /// If a 68k ever struggles with that, slow the COALESCER down — do not go back to
    /// sending fragments, because fragments do not work.
    /// - Parameter transition: whether this redraw is a DELIBERATE take, which is the
    ///   only time the chosen wipe should run.
    ///
    /// ── WHY EDITING AND TAKING ARE NOT THE SAME REDRAW ──────────────────────────
    ///
    /// Every control here ends in a full page plus `SHOW`, because Scala works in
    /// pages and fragments are silently ignored (see above). But `SHOW` performs the
    /// WIPE, and the wipe defaulted to `fade` — so nudging the colour, moving the
    /// text, or touching any of the fourteen controls that emit a page made the whole
    /// screen fade out and back in. On a titler that is on air, that is not a cosmetic
    /// problem: it is a transition nobody asked for, in the middle of a show.
    ///
    /// A wipe belongs to a TAKE — the deliberate act of putting a new page up. While
    /// you are still building the page, the redraw should be instant, which is what
    /// Scala's `cut` is. So edits cut, and `take()` uses whatever wipe the operator
    /// dialled in. That is also how the hardware this imitates behaves: you set the
    /// look on preview, then take it to air with the transition you chose.
    public func page(transition: Bool = false) -> [TitlerCommand] {
        // `cut` is index 0 and is Scala's instant one — verified against the disc's own
        // wipe list, not assumed.
        let redraw = transition
            ? currentWipe()
            : ScalaLingo.wipe(ScalaLingo.instantWipe, direction: nil, speed: state.wipeSpeed)
        var commands: [TitlerCommand] = [
            ScalaLingo.screen(
                width: screen.width, height: screen.height,
                interlaced: screen.isInterlaced),
            currentPalette(),
            ScalaLingo.colour(fill: 1),
            currentFont(),
            currentAttributes(),
            redraw,
            ScalaLingo.textWipe(ScalaLingo.wipes[state.textWipeIndex], speed: state.wipeSpeed)
        ]

        // Backdrop, then bar, then brush, then text — back to front, because that is
        // the order they have to be painted in for the text to end up on top.
        if state.hasBackdrop, backdrops.indices.contains(state.backdropIndex) {
            commands.append(ScalaLingo.picture(backdrops[state.backdropIndex]))
        }
        if let box = currentBox() { commands.append(box) }
        if let brush = currentBrush() { commands.append(brush) }
        commands.append(contentsOf: currentTextLines())

        if state.isCycling { commands.append(ScalaLingo.cycle(true)) }
        commands.append(ScalaLingo.show())
        return commands
    }

    /// Where text should sit for a given alignment, before anyone drags it.
    ///
    /// The margin is a twentieth of the screen — the safe-area habit, near enough, and
    /// the only figure here that is a judgement rather than a measurement.
    private func anchorX(forAlignment index: Int) -> Int {
        let margin = screen.width / 20
        switch ScalaLingo.alignments[min(index, ScalaLingo.alignments.count - 1)] {
        case "center", "centre": return screen.width / 2
        case "right": return screen.width - margin
        default: return margin
        }
    }

    /// The bar behind the text, when the fader is above its "no bar" bottom.
    private func currentBox() -> TitlerCommand? {
        guard state.boxHeight > 0.02 else { return nil }
        let height = Int(Double(screen.height) * state.boxHeight * 0.4)
        let top = max(state.textY - height / 3, 0)
        return ScalaLingo.box(
            x1: 0, y1: top,
            x2: screen.width - 1, y2: min(top + height, screen.height - 1))
    }

    /// The placed graphic, when one has been chosen.
    private func currentBrush() -> TitlerCommand? {
        guard let file = state.brushFile, state.brushScale > 0 else { return nil }
        let width = Int(Double(screen.width) * state.brushScale)
        let height = Int(Double(screen.height) * state.brushScale)
        return ScalaLingo.brush(
            x: (screen.width - width) / 2, y: (screen.height - height) / 2,
            file: file, width: max(width, 1), height: max(height, 1))
    }

    // MARK: - The lines the state currently implies

    private func currentWipe() -> TitlerCommand {
        ScalaLingo.wipe(
            ScalaLingo.wipes[state.wipeIndex],
            direction: state.directionIndex.map { ScalaLingo.directions[$0] },
            speed: state.wipeSpeed)
    }

    private func currentFont() -> TitlerCommand {
        ScalaLingo.font(faceName, size: state.fontSize)
    }

    /// How many faces there are to choose between.
    public var faceCount: Int {
        fontCatalogue.isEmpty ? ScalaLingo.fonts.count : fontCatalogue.count
    }

    /// The chosen face's name, from the catalogue when there is one.
    public var faceName: String {
        if let face = currentFace { return face.name }
        return ScalaLingo.fonts[min(state.fontIndex, ScalaLingo.fonts.count - 1)]
    }

    /// The sizes the chosen face offers.
    public var faceSizes: [Int] { currentFace?.sizes ?? [] }

    private func currentText() -> TitlerCommand {
        ScalaLingo.text(x: state.textX, y: state.textY, state.text, line: 0)
    }

    /// Both lines, the second below the first.
    ///
    /// The gap is the type size plus a fifth of it — the leading Scala's own scripts
    /// use, near enough, and the only figure here that is a judgement rather than a
    /// measurement.
    private func currentTextLines() -> [TitlerCommand] {
        var lines = [currentText()]
        guard !state.textTwo.trimmingCharacters(in: .whitespaces).isEmpty else { return lines }
        let leading = state.fontSize + state.fontSize / 5
        lines.append(ScalaLingo.text(
            x: state.textX, y: min(state.textY + leading, screen.height - 1),
            state.textTwo, line: 1))
        return lines
    }

    /// The ATTRIBUTES line the state implies.
    ///
    /// One line carrying alignment, edging and italics, because Scala takes them
    /// together — sending three lines would leave the last one winning and the other
    /// two silently discarded.
    private func currentAttributes() -> TitlerCommand {
        var words = ["antialias", "remap", ScalaLingo.alignments[state.alignmentIndex]]
        let edge = ScalaLingo.edgeStyles[state.edgeIndex]
        if edge != "none" { words.append(edge) }
        if state.isItalic { words.append("italics") }
        return ScalaLingo.attributes(words)
    }

    private func currentPalette() -> TitlerCommand {
        // Entry 0 is the background — on the Amiga it is also the genlock key, which is
        // why the background colour control reaches this one specifically.
        ScalaLingo.palette([state.backgroundColour, state.textColour])
    }

    // MARK: - Small conversions

    private func scaled(_ value: Double, into range: ClosedRange<Int>) -> Int {
        let span = Double(range.upperBound - range.lowerBound)
        return range.lowerBound + Int((value * span).rounded())
    }

    private func invertedSpeed(_ value: Double) -> Int {
        let range = ScalaLingo.speedRange
        let span = Double(range.upperBound - range.lowerBound)
        return range.upperBound - Int((value * span).rounded())
    }
}

/// The controls offered for a given program.
public enum TitlerControlSet {

    /// The controls for a program, or none when it has no script port to drive.
    ///
    /// Only Scala has a panel so far, and that is the honest state: the others need
    /// their own dialect read off their own media before anything can claim to drive
    /// them. Returning an empty set makes the EMU tab show them greyed with a reason
    /// rather than offering knobs that go nowhere.
    public static func controls(for program: TitlerProgram) -> [TitlerControl] {
        guard let port = program.scriptPort else { return [] }
        // Matched on the PORT, not the product name. Scala MM300 and MM400 are the same
        // dialect answering on the same port — ScalaLingo was read off the MM400 disc —
        // so a name switch means nothing to the commands. Keying this on the name meant
        // that changing the default program to MM400 silently emptied the panel: every
        // slider disappeared and the tab explained that the vocabulary had not been read
        // off the media yet, which was not true and pointed at nothing that could be
        // fixed. A control set belongs to a language, not to a product name.
        switch port {
        case ScalaLingo.portName: return ScalaTitlerPanel.controls
        default: return []
        }
    }

    /// The controls, grouped the way a titler is actually operated.
    ///
    /// ── WHY THE GROUPING IS DATA AND NOT LAYOUT CODE ────────────────────────────
    ///
    /// Because the view is meant to draw whatever the control set contains and nothing
    /// else, and a grouping that lives in the view is a second, invisible list that
    /// drifts from the first. This way a control added to the set lands in a named
    /// section or it does not appear at all, which is the loud failure rather than the
    /// quiet one.
    ///
    /// The order follows what an operator reaches for, borrowed from the shape every
    /// modern titler settles on — the words first, then how they look, then where they
    /// sit, then how they arrive.
    public static func groups(for program: TitlerProgram) -> [(title: String, controls: [TitlerControl])] {
        let all = controls(for: program)
        guard !all.isEmpty else { return [] }

        func pick(_ functions: [TitlerFunction]) -> [TitlerControl] {
            functions.compactMap { function in all.first { $0.function == function } }
        }

        let sections: [(String, [TitlerFunction])] = [
            ("TYPE",       [.fontFace, .fontSize, .decoration, .italic, .alignment]),
            ("COLOUR",     [.textColour, .backgroundColour, .colourCycle]),
            ("POSITION",   [.textX, .textY, .box]),
            ("BACKGROUND", [.backdrop, .brushScale]),
            ("TRANSITION", [.wipe, .wipeDirection, .wipeSpeed, .textWipe]),
            ("PAGE",       [.page, .hold])
        ]

        var grouped = sections.map { (title: $0.0, controls: pick($0.1)) }
            .filter { !$0.controls.isEmpty }

        // Anything the sections above forgot. A control that exists and is not shown is
        // the failure this catches; it lands in its own visible group rather than
        // vanishing.
        let placed = Set(grouped.flatMap { $0.controls.map(\.function) })
        let missed = all.filter { !placed.contains($0.function) }
        if !missed.isEmpty { grouped.append((title: "OTHER", controls: missed)) }

        return grouped
    }

    /// Why a program has no panel yet.
    public static func noPanelReason(for program: TitlerProgram) -> String? {
        guard !controls(for: program).isEmpty else {
            return program.scriptPort == nil
                ? "\(program.name) has no script port — it would have to be driven by "
                    + "keystrokes, which is not built"
                : "\(program.name) has a script port, but its command vocabulary has "
                    + "not been read off its media yet"
        }
        return nil
    }
}
