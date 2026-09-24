//
//  AVE5Wipe.swift — the Panasonic WJ-AVE5's WIPE MODE block, as one transition.
//
//  Purpose : The AVE-5 does not have a list of wipes. It has five pattern keys that
//            COMBINE — two horizontal edges, two vertical edges and a circle — and
//            the lit combination IS the pattern: 31 combinations, times three MULTI
//            states, is where the manual's "98 wipe patterns" comes from (plus
//            P-in-P and cut). This type is that front panel: which keys are lit, what
//            a press does, and what the keys add up to. The shader draws it.
//  Inputs  : key presses (`press`), the joystick positioner, or the state as
//            parameter values (codes 62F–69F).
//  Outputs : the state, as parameter values (CrossfadeNode hands its fields to the
//            blend shader), and `arrives` — the wipe's field on the CPU, which the
//            fader key draws with and the tests hold the shader to.
//  Connects: Transition.ave5, CrossfadeNode (reads the state, keeps the ONE-WAY
//            latch), `ave5Mask` in MetalContext's shader, the AVE-5 popover on the
//            fader panel, and ShellController (turns learned MIDI keys into presses).
//  Extend  : P-IN-P and CUT-MULTI are the two things on the block not emulated here
//            — both are picture-in-picture, which is out of scope. A new key would be
//            a `Key` case, its press behaviour in `press`, and a 6xG trigger code.
//
//  ── THE SOURCE ──────────────────────────────────────────────────────────────────
//
//  WJ-AVE5 Operating Instructions (English section): the WIPE PATTERNS table on
//  p.5, controls 5–10, 45, 53 and 54 on pp.5–8, and "Operating Procedure" 4–8 on
//  p.13. Page numbers are the manual's own.
//
//  ── HOW THE KEYS COMBINE (read off the table) ───────────────────────────────────
//
//  Each edge key is a ramp across the screen, "B arrives from this side":
//
//      A|B  B arrives from the RIGHT       A/B  B arrives from the BOTTOM
//      B|A  B arrives from the LEFT        B/A  B arrives from the TOP
//
//  Both keys of one axis fold that ramp at the centre — B opens from the middle.
//  Keys on BOTH axes, without the circle, take the larger of the two (a box): one
//  of each is a corner box, three is a box off the middle of an edge, all four is a
//  box in the centre. The CIRCLE key changes the combining from "larger of" to
//  "sum of", which turns every box into its diagonal twin: corner → diagonal,
//  one edge key → a chevron, three keys → a triangle, all five → a diamond. The
//  circle alone is a circle. Two rows the manual draws as striped, textured shapes
//  (both keys of ONE axis plus the circle) are generator artefacts; the shader
//  approximates them.
//
//  ── THE KEYS THAT CYCLE ─────────────────────────────────────────────────────────
//
//      MULTI        ×4 → ×16 → off                     (p.6, control 8)
//      WIPE         Normal → Border → Soft → Normal     (p.8, control 53)
//      BACK COLOUR  White → Yellow → … → Black → White  (p.5, control 5)
//
//  The five pattern keys, ONE-WAY and REVERSE are plain toggles.
//

import Foundation

/// The state of an AVE-5 WIPE MODE block.
public struct AVE5Wipe: Equatable, Sendable {

    // MARK: - Pattern keys

    /// The five pattern keys. Raw values are the bits the shader reads.
    public struct PatternKeys: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue & 0b11111 }

        /// `A|B` — A left, B right: B arrives from the right edge.
        public static let fromRight = PatternKeys(rawValue: 1 << 0)
        /// `B|A` — B arrives from the left edge.
        public static let fromLeft = PatternKeys(rawValue: 1 << 1)
        /// `A/B` — A over B: B arrives from the bottom.
        public static let fromBottom = PatternKeys(rawValue: 1 << 2)
        /// `B/A` — B over A: B arrives from the top.
        public static let fromTop = PatternKeys(rawValue: 1 << 3)
        /// The circle key.
        public static let circle = PatternKeys(rawValue: 1 << 4)

        /// All four edge keys.
        public static let allEdges: PatternKeys = [.fromRight, .fromLeft, .fromBottom, .fromTop]
    }

    /// How many times MULTI tiles the pattern.
    public enum Multi: Int, CaseIterable, Sendable {
        case off = 0
        /// Pressed once: the pattern four times, 2 × 2.
        case x4 = 1
        /// Pressed twice: sixteen times, 4 × 4.
        case x16 = 2

        /// Tiles along each side of the screen.
        public var tilesPerSide: Int {
            switch self {
            case .off: 1
            case .x4: 2
            case .x16: 4
            }
        }

        /// Label for the key's lamp.
        public var label: String {
            switch self {
            case .off: "MULTI"
            case .x4: "×4"
            case .x16: "×16"
            }
        }
    }

    /// What the edge of the wipe looks like — the WIPE key's three states.
    public enum EdgeMode: Int, CaseIterable, Sendable {
        /// A hard edge.
        case normal = 0
        /// A band of the BACK COLOUR along the edge.
        case border = 1
        /// A dimmed, softened edge.
        case soft = 2

        /// Label for the key.
        public var label: String {
            switch self {
            case .normal: "NORMAL"
            case .border: "BORDER"
            case .soft: "SOFT"
            }
        }
    }

    /// The eight back colours, in the order the BACK COLOUR key steps through them
    /// (manual p.5, control 5).
    public enum BackColour: Int, CaseIterable, Sendable {
        case white = 0, yellow, cyan, green, magenta, red, blue, black

        /// Full-intensity RGB, 0...1. Kept below legal white/black is the output
        /// stage's job, not this table's.
        public var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .white: (1, 1, 1)
            case .yellow: (1, 1, 0)
            case .cyan: (0, 1, 1)
            case .green: (0, 1, 0)
            case .magenta: (1, 0, 1)
            case .red: (1, 0, 0)
            case .blue: (0, 0, 1)
            case .black: (0, 0, 0)
            }
        }

        public var displayName: String {
            switch self {
            case .white: "White"
            case .yellow: "Yellow"
            case .cyan: "Cyan"
            case .green: "Green"
            case .magenta: "Magenta"
            case .red: "Red"
            case .blue: "Blue"
            case .black: "Black"
            }
        }
    }

    /// Every key on the block that a press can reach.
    public enum Key: Int, CaseIterable, Sendable {
        case fromRight, fromLeft, fromBottom, fromTop, circle
        case multi, wipe, oneWay, reverse, backColour

        /// Label for logs and tooltips — the legend on the hardware key.
        public var legend: String {
            switch self {
            case .fromRight: "A|B"
            case .fromLeft: "B|A"
            case .fromBottom: "A/B"
            case .fromTop: "B/A"
            case .circle: "Circle"
            case .multi: "MULTI"
            case .wipe: "WIPE"
            case .oneWay: "ONE-WAY"
            case .reverse: "REVERSE"
            case .backColour: "BACK COLOUR"
            }
        }

        /// The pattern key this is, for the five that are pattern keys.
        public var patternKey: PatternKeys? {
            switch self {
            case .fromRight: .fromRight
            case .fromLeft: .fromLeft
            case .fromBottom: .fromBottom
            case .fromTop: .fromTop
            case .circle: .circle
            default: nil
            }
        }

        /// The momentary code a learned MIDI key writes to press this key (6xG).
        public var triggerCode: ParamCode {
            switch self {
            case .fromRight: .ave5PressFromRight
            case .fromLeft: .ave5PressFromLeft
            case .fromBottom: .ave5PressFromBottom
            case .fromTop: .ave5PressFromTop
            case .circle: .ave5PressCircle
            case .multi: .ave5PressMulti
            case .wipe: .ave5PressWipe
            case .oneWay: .ave5PressOneWay
            case .reverse: .ave5PressReverse
            case .backColour: .ave5PressBackColour
            }
        }
    }

    // MARK: - State

    /// Which pattern keys are lit. None lit is the manual's CUT: the picture
    /// switches at the middle of the lever's travel (p.13, 8-1).
    public var keys: PatternKeys
    public var multi: Multi
    public var edge: EdgeMode
    /// ONE-WAY: the wipe keeps its direction when the lever comes back (p.13, 6).
    public var oneWay: Bool
    /// REVERSE: B arrives where A would have stayed (p.13, 5).
    public var reverse: Bool
    /// The border colour (and, on the hardware, the back colour source).
    public var backColour: BackColour
    /// The joystick positioner, 0...1 across the screen (or across a tile under
    /// MULTI); 0.5 is the centre. Only moves the three patterns the manual marks Ⓟ.
    public var positionX: Double
    public var positionY: Double

    /// Power-on state: A|B lit, everything else off, the positioner centred.
    public init(
        keys: PatternKeys = .fromRight,
        multi: Multi = .off,
        edge: EdgeMode = .normal,
        oneWay: Bool = false,
        reverse: Bool = false,
        backColour: BackColour = .white,
        positionX: Double = 0.5,
        positionY: Double = 0.5
    ) {
        self.keys = keys
        self.multi = multi
        self.edge = edge
        self.oneWay = oneWay
        self.reverse = reverse
        self.backColour = backColour
        self.positionX = positionX
        self.positionY = positionY
    }

    // MARK: - Pressing keys

    /// What one press of a key does, exactly as the manual describes it.
    public mutating func press(_ key: Key) {
        if let pattern = key.patternKey {
            keys.formSymmetricDifference(pattern)
            return
        }
        switch key {
        case .multi:
            multi = Multi(rawValue: (multi.rawValue + 1) % Multi.allCases.count) ?? .off
        case .wipe:
            edge = EdgeMode(rawValue: (edge.rawValue + 1) % EdgeMode.allCases.count) ?? .normal
        case .oneWay:
            oneWay.toggle()
        case .reverse:
            reverse.toggle()
        case .backColour:
            backColour = BackColour(
                rawValue: (backColour.rawValue + 1) % BackColour.allCases.count) ?? .white
        default:
            break
        }
    }

    /// Whether a key's lamp is lit. MULTI is lit in both its ×4 and ×16 states, and
    /// WIPE is lit for Border and Soft, as on the hardware.
    public func isLit(_ key: Key) -> Bool {
        if let pattern = key.patternKey { return keys.contains(pattern) }
        switch key {
        case .multi: return multi != .off
        case .wipe: return edge != .normal
        case .oneWay: return oneWay
        case .reverse: return reverse
        case .backColour: return backColour != .white
        default: return false
        }
    }

    // MARK: - What the keys add up to

    /// The shape a combination of keys makes, named as the manual draws it.
    public enum Shape: Equatable, Sendable {
        case cut
        case edge
        case split
        case cornerBox
        case edgeBox
        case centreBox
        case circle
        case diagonal
        case chevron
        case triangle
        case diamond
        /// One axis folded, plus the circle — the textured rows of the table.
        case textured

        public var displayName: String {
            switch self {
            case .cut: "Cut"
            case .edge: "Edge"
            case .split: "Split"
            case .cornerBox: "Corner box"
            case .edgeBox: "Edge box"
            case .centreBox: "Box"
            case .circle: "Circle"
            case .diagonal: "Diagonal"
            case .chevron: "Arrow"
            case .triangle: "Triangle"
            case .diamond: "Diamond"
            case .textured: "Textured"
            }
        }
    }

    /// The shape the lit keys make.
    public var shape: Shape {
        let horizontal = keys.intersection([.fromRight, .fromLeft]).rawValueCount
        let vertical = keys.intersection([.fromBottom, .fromTop]).rawValueCount
        let circle = keys.contains(.circle)
        switch (horizontal, vertical, circle) {
        case (0, 0, false): return .cut
        case (0, 0, true): return .circle
        case (1, 0, false), (0, 1, false): return .edge
        case (2, 0, false), (0, 2, false): return .split
        case (1, 1, false): return .cornerBox
        case (2, 1, false), (1, 2, false): return .edgeBox
        case (2, 2, false): return .centreBox
        case (1, 0, true), (0, 1, true): return .chevron
        case (2, 0, true), (0, 2, true): return .textured
        case (1, 1, true): return .diagonal
        case (2, 1, true), (1, 2, true): return .triangle
        default: return .diamond // (2, 2, true)
        }
    }

    /// Whether the joystick moves this pattern — the three rows marked Ⓟ in the
    /// table: the centre box, the circle and the diamond.
    public var isPositionable: Bool {
        switch shape {
        case .centreBox, .circle, .diamond: true
        default: false
        }
    }

    // MARK: - Parameters (6xF state, 6xG presses)

    /// Reads the state from parameter values. Missing values keep the power-on
    /// default for that field, so a half-written template still loads.
    public init(values: (ParamCode) -> Double?) {
        self.init()
        if let v = values(.ave5Keys) {
            keys = PatternKeys(rawValue: NormalisedSweep.index(v, count: 32))
        }
        if let v = values(.ave5Multi) {
            multi = Multi(rawValue: NormalisedSweep.index(v, count: Multi.allCases.count)) ?? .off
        }
        if let v = values(.ave5Edge) {
            edge = EdgeMode(rawValue: NormalisedSweep.index(v, count: EdgeMode.allCases.count)) ?? .normal
        }
        if let v = values(.ave5OneWay) { oneWay = v > 0.5 }
        if let v = values(.ave5Reverse) { reverse = v > 0.5 }
        if let v = values(.ave5BackColour) {
            backColour = BackColour(
                rawValue: NormalisedSweep.index(v, count: BackColour.allCases.count)) ?? .white
        }
        if let v = values(.ave5PositionX) { positionX = NormalisedSweep.clamp(v) }
        if let v = values(.ave5PositionY) { positionY = NormalisedSweep.clamp(v) }
    }

    /// The state as parameter values, the inverse of `init(values:)`.
    public var parameterValues: [(ParamCode, Double)] {
        [
            (.ave5Keys, NormalisedSweep.value(forIndex: keys.rawValue, count: 32)),
            (.ave5Multi, NormalisedSweep.value(forIndex: multi.rawValue, count: Multi.allCases.count)),
            (.ave5Edge, NormalisedSweep.value(forIndex: edge.rawValue, count: EdgeMode.allCases.count)),
            (.ave5OneWay, oneWay ? 1 : 0),
            (.ave5Reverse, reverse ? 1 : 0),
            (.ave5BackColour, NormalisedSweep.value(
                forIndex: backColour.rawValue, count: BackColour.allCases.count)),
            (.ave5PositionX, positionX),
            (.ave5PositionY, positionY)
        ]
    }

    /// The state codes, with their power-on defaults, for a node to register.
    public static var parameters: [Parameter] {
        AVE5Wipe().parameterValues.map { Parameter(code: $0.0, range: 0...1, defaultValue: $0.1) }
    }

    /// The press codes, each a momentary 0/1, for a node to register.
    public static var triggerParameters: [Parameter] {
        Key.allCases.map { Parameter(code: $0.triggerCode, range: 0...1, defaultValue: 0) }
    }
}

// MARK: - The field on the CPU

extension AVE5Wipe {

    /// Whether B has arrived at one point, for a hard edge — the CPU twin of
    /// `ave5Mask` in the Metal source.
    ///
    /// Two uses: the fader key draws the armed pattern with it, and a test holds the
    /// shader to it pixel by pixel, which is what stops the two drifting apart. It
    /// is the hard edge only — the border band and the soft edge are left out — but
    /// it does include the circle's zigzag, which moves which pixels B has reached.
    ///
    /// - Parameters:
    ///   - u: 0...1 across, left to right.
    ///   - v: 0...1 down, top to bottom.
    ///   - progress: the fader, 0...1, before REVERSE and ONE-WAY (pass `reversed`).
    ///   - aspect: width over height of the picture.
    ///   - pixel: the output pixel, for the two textured patterns' line pattern.
    public func arrives(
        u: Double, v: Double, progress: Double, aspect: Double,
        reversed: Bool = false, pixel: (x: Double, y: Double) = (0, 0)
    ) -> Bool {
        let t = reversed ? 1 - progress : progress
        let arrived: Bool
        if keys.isEmpty {
            arrived = t >= 0.5
        } else {
            // The circle's zigzag edge: `kAVE5ZigzagColumns` in the shader.
            var at = u
            if keys == .circle {
                at = ((u * Self.zigzagColumns).rounded(.down) + 0.5) / Self.zigzagColumns
            }
            let tiles = Double(multi.tilesPerSide)
            let cellY = (v * tiles).rounded(.down)
            var q = (x: at * tiles - (at * tiles).rounded(.down), y: v * tiles - cellY)
            if isMirroredDiagonal, Int(cellY) % 2 == 1 { q.y = 1 - q.y }
            let c = isPositionable ? (x: positionX, y: positionY) : (x: 0.5, y: 0.5)
            let field = rawField(q, c, aspect, pixel)
            // Corners, edge midpoints, centre — see the shader for why these nine.
            let probes = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0),
                          (0.5, 0.0), (0.5, 1.0), (0.0, 0.5), (1.0, 0.5), (0.5, 0.5)]
            let reach = probes.map { rawField((x: $0.0, y: $0.1), c, aspect, pixel) }.max() ?? 1
            let threshold = t * (1 + 2 * Self.edgeReach) - Self.edgeReach
            arrived = field / max(reach, 1e-4) < threshold
        }
        return reversed ? !arrived : arrived
    }

    /// `kAVE5EdgeReach` in the shader.
    static let edgeReach = 0.05

    /// `kAVE5ZigzagColumns` in the shader.
    static let zigzagColumns = 90.0

    /// Diagonals under MULTI mirror alternate rows of tiles (see the shader).
    private var isMirroredDiagonal: Bool { shape == .diagonal }

    /// `ave5RawField` in the shader.
    private func rawField(
        _ q: (x: Double, y: Double), _ c: (x: Double, y: Double), _ aspect: Double,
        _ pixel: (x: Double, y: Double)
    ) -> Double {
        func axis(_ high: Bool, _ low: Bool, _ value: Double, _ centre: Double) -> Double? {
            if high && low { return 2 * abs(value - centre) }
            if high { return 1 - value }
            if low { return value }
            return nil
        }
        let ax = axis(keys.contains(.fromRight), keys.contains(.fromLeft), q.x, c.x)
        let ay = axis(keys.contains(.fromBottom), keys.contains(.fromTop), q.y, c.y)
        guard keys.contains(.circle) else {
            if let ax, let ay { return max(ax, ay) }
            return ax ?? ay ?? 0
        }
        switch (ax, ay) {
        case (nil, nil):
            let dx = (q.x - c.x) * aspect
            let dy = q.y - c.y
            return (dx * dx + dy * dy).squareRoot()
        case let (ax?, ay?):
            return ax + ay
        case let (ax?, nil):
            let other = 2 * abs(q.y - 0.5)
            guard keys.isSuperset(of: [.fromRight, .fromLeft]) else { return ax + 0.5 * other }
            let odd = Int(pixel.y.rounded(.down)) % 2 == 1
            return odd ? 1 - other : ax + (1 - other)
        case let (nil, ay?):
            let other = 2 * abs(q.x - 0.5)
            guard keys.isSuperset(of: [.fromBottom, .fromTop]) else { return ay + 0.5 * other }
            // kAVE5TextureColumnPixels in the shader.
            let odd = Int((pixel.x / 4).rounded(.down)) % 2 == 1
            return odd ? 1 - other : 2 - ay - other
        }
    }
}

private extension AVE5Wipe.PatternKeys {
    /// How many keys are lit.
    var rawValueCount: Int { rawValue.nonzeroBitCount }
}
