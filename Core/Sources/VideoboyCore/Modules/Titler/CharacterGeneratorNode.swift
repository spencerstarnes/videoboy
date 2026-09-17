//
//  CharacterGeneratorNode.swift — the clean, native titler (SPEC 18.1).
//
//  Purpose : A basic character generator scoped to about Premiere/Resolve's "basic
//            text" — not a motion-graphics suite. Built on Core Text for layout and
//            rendering. Works BOTH as a source (its own channel, text over a plain
//            background) and as a bus effect (text composited over whatever is
//            already there), because SPEC 18.1 asks for both from one module rather
//            than two.
//  Inputs  : zero (as a source) or one (as an overlay) upstream texture, plus every
//            parameter below.
//  Outputs  : one MTLTexture per frame — the input (if any) with type drawn over it,
//            or a plain background with type on it if there was no input.
//  Connects: CRTGeometry (title-safe placement), BroadcastSafety (the fill colour's
//            legality warning), CompositeCodecNode (the "period" preset routes
//            through it rather than re-implementing NTSC degradation).
//  Extend  : a new visual property is a new stored var plus a row in `parameters`,
//            following exactly the pattern the numeric ones below already set.
//
//  Two things worth knowing before touching this file:
//
//  1. KERNING VS TRACKING share one CoreText attribute, `kCTKernAttributeName`, which
//     is genuinely overloaded: a value of exactly 0 disables the font's own built-in
//     pair kerning; any other value both keeps pair kerning on AND adds that many
//     points of uniform tracking; omitting the attribute entirely means "default pair
//     kerning, no added tracking". SPEC 18.1 asks for kerning and tracking as two
//     separate controls, so this file keeps them as two separate PARAMETERS and only
//     collapses them into CoreText's one attribute at the point of drawing — see
//     `kernAttributeValue`.
//
//  2. POSITION IS THE ANCHOR. SPEC 18.1 says "position/anchor" as one bullet; rather
//     than a second anchor-corner enum on top of position, position (already a
//     universal code, §13) IS where the anchor point sits, and alignment decides
//     which way the text runs from it. That is one concept doing the work SPEC
//     described in two words, not a shortcut around either.
//

import CoreText
import CoreGraphics
import Foundation
import Metal

// MARK: - Small value types

/// A colour without AppKit. Core has no AppKit, and CoreText's own colour attribute
/// wants a `CGColor` anyway, so this is the whole of what a colour needs to be here.
public struct TitlerColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = TitlerColor(red: 1, green: 1, blue: 1)
    public static let black = TitlerColor(red: 0, green: 0, blue: 0)
    /// A conventional titler yellow-white — legible on most footage, and, unlike
    /// pure white, does not sit exactly at 100 IRE where it has no headroom at all.
    public static let defaultFill = TitlerColor(red: 0.95, green: 0.95, blue: 0.85)

    public var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Whether this colour, filled across the frame, would itself be broadcast-legal.
    ///
    /// Reuses `BroadcastSafety.analyse` on a small swatch rather than re-deriving IRE
    /// arithmetic a second time — the question "is this colour legal" and "is this
    /// picture legal" are the same question at different sizes.
    public var broadcastReport: BroadcastSafetyReport {
        var swatch = ImageBuffer(width: 8, height: 8)
        let r = UInt8(clamping: Int((red * 255).rounded()))
        let g = UInt8(clamping: Int((green * 255).rounded()))
        let b = UInt8(clamping: Int((blue * 255).rounded()))
        for y in 0..<8 {
            for x in 0..<8 { swatch.setPixel(x: x, y: y, r: r, g: g, b: b) }
        }
        return BroadcastSafety.analyse(swatch)
    }
}

/// Paragraph alignment, swept 0...1 like every other small-set parameter here.
public enum TitlerAlignment: Int, CaseIterable, Sendable {
    case left, center, right, justified

    public var displayName: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .justified: "Justified"
        }
    }

    var ctAlignment: CTTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    public static func from(normalised value: Double) -> TitlerAlignment {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    public var normalisedPosition: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }
}

/// Font weight bucket. A sweep across a handful of named weights rather than a
/// continuous value, because "weight" is not continuous on most font families —
/// there is no font file for 0.37 of the way from Regular to Bold.
public enum TitlerWeight: Int, CaseIterable, Sendable {
    case regular, medium, semibold, bold, heavy

    public var displayName: String {
        switch self {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        }
    }

    /// CoreText symbolic traits do not have a semibold/medium bit of their own on
    /// every font, so weight is applied through `CTFontCreateWithFontDescriptor`'s
    /// weight trait, which every system font honours.
    var ctWeight: CGFloat {
        switch self {
        case .regular: 0.0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        }
    }

    public static func from(normalised value: Double) -> TitlerWeight {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    public var normalisedPosition: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }
}

/// How the type moves, if at all. Clock-syncable per SPEC 18.1.
public enum TitlerRollMode: Int, CaseIterable, Sendable {
    /// Static, at its placed position.
    case off
    /// Moves upward, for credits.
    case roll
    /// Moves sideways, for a news-style ticker.
    case crawl
    /// Cuts on at its position and holds — the "reveal" is the appearance itself,
    /// which the wet/dry fade already provides when driven by an LFO or a cut.
    case reveal

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .roll: "Roll"
        case .crawl: "Crawl"
        case .reveal: "Reveal"
        }
    }

    public static func from(normalised value: Double) -> TitlerRollMode {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    public var normalisedPosition: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }
}

// MARK: - The node

/// Draws styled text, natively, as a source or an overlay.
public final class CharacterGeneratorNode: Node {

    public let identifier: String
    public let kind: NodeKind = .source
    public var latencyInFrames: Int { 0 }

    // MARK: Non-numeric state — set directly, like `mediaURL` on ClipSourceNode,
    // not through the float-only param registry.

    /// What is drawn. Multi-line: newlines break lines exactly as typed.
    public var text: String = ""
    /// A system font family name. Falls back to the system font if not found.
    public var fontFamily: String = ".AppleSystemUIFont"
    public var fillColor: TitlerColor = .defaultFill
    public var outlineColor: TitlerColor = .black
    public var shadowColor: TitlerColor = .black

    // MARK: Numeric state — every one of these has a param code and is therefore
    // detect- and audio-react-mappable (SPEC 18.1's last bullet).

    /// Reused universal codes: this is what makes the CG a citizen of the graph like
    /// everything else rather than a special case.
    public var opacity: Double = 1.0
    public var wetDry: Double = 1.0
    public var positionX: Double = 0.5
    public var positionY: Double = 0.5
    public var scale: Double = 1.0

    public var fontSize: Double = 36
    public var fontWeightPosition: Double = 0
    public var alignmentPosition: Double = TitlerAlignment.center.normalisedPosition
    public var kerningEnabled: Double = 1.0
    public var tracking: Double = 0
    public var leading: Double = 0
    public var outlineWidth: Double = 0
    public var shadowOffsetX: Double = 0
    public var shadowOffsetY: Double = 0
    public var shadowBlur: Double = 0
    public var shadowOpacity: Double = 0.6
    public var rollModePosition: Double = TitlerRollMode.off.normalisedPosition
    /// Screen-heights (roll) or screen-widths (crawl) per bar.
    public var rollRate: Double = 0.25
    public var periodPresetEnabled: Double = 0
    public var safeZoneClampEnabled: Double = 1.0

    private let context: MetalContext?
    private var readbackRenderer: OffscreenRenderer?
    /// Owned rather than shared, so the period preset never fights a bus's own
    /// composite codec over generation count or wobble phase.
    private lazy var periodCodec: CompositeCodecNode? = context.map {
        CompositeCodecNode(identifier: "\(identifier).period", context: $0)
    }

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public var parameters: [Parameter] {
        [
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .positionX, range: 0...1, defaultValue: 0.5),
            Parameter(code: .positionY, range: 0...1, defaultValue: 0.5),
            Parameter(code: .scale, range: 0.1...4, defaultValue: 1),
            Parameter(code: .cgFontSize, range: 8...160, defaultValue: 36),
            Parameter(code: .cgFontWeight, range: 0...1, defaultValue: 0),
            Parameter(code: .cgAlignment, range: 0...1, defaultValue: TitlerAlignment.center.normalisedPosition),
            Parameter(code: .cgKerningEnabled, range: 0...1, defaultValue: 1),
            Parameter(code: .cgTracking, range: -10...40, defaultValue: 0),
            Parameter(code: .cgLeading, range: -20...60, defaultValue: 0),
            Parameter(code: .cgOutlineWidth, range: 0...12, defaultValue: 0),
            Parameter(code: .cgShadowOffsetX, range: -20...20, defaultValue: 0),
            Parameter(code: .cgShadowOffsetY, range: -20...20, defaultValue: 0),
            Parameter(code: .cgShadowBlur, range: 0...30, defaultValue: 0),
            Parameter(code: .cgShadowOpacity, range: 0...1, defaultValue: 0.6),
            Parameter(code: .cgRollMode, range: 0...1, defaultValue: TitlerRollMode.off.normalisedPosition),
            Parameter(code: .cgRollRate, range: 0...4, defaultValue: 0.25),
            Parameter(code: .cgPeriodPreset, range: 0...1, defaultValue: 0),
            Parameter(code: .cgSafeZoneClamp, range: 0...1, defaultValue: 1)
        ]
    }

    public func applyParameters(from registry: ParamRegistry) {
        if let v = registry.value(slot: identifier, code: .opacity) { opacity = v }
        if let v = registry.value(slot: identifier, code: .wetDry) { wetDry = v }
        if let v = registry.value(slot: identifier, code: .positionX) { positionX = v }
        if let v = registry.value(slot: identifier, code: .positionY) { positionY = v }
        if let v = registry.value(slot: identifier, code: .scale) { scale = v }
        if let v = registry.value(slot: identifier, code: .cgFontSize) { fontSize = v }
        if let v = registry.value(slot: identifier, code: .cgFontWeight) { fontWeightPosition = v }
        if let v = registry.value(slot: identifier, code: .cgAlignment) { alignmentPosition = v }
        if let v = registry.value(slot: identifier, code: .cgKerningEnabled) { kerningEnabled = v }
        if let v = registry.value(slot: identifier, code: .cgTracking) { tracking = v }
        if let v = registry.value(slot: identifier, code: .cgLeading) { leading = v }
        if let v = registry.value(slot: identifier, code: .cgOutlineWidth) { outlineWidth = v }
        if let v = registry.value(slot: identifier, code: .cgShadowOffsetX) { shadowOffsetX = v }
        if let v = registry.value(slot: identifier, code: .cgShadowOffsetY) { shadowOffsetY = v }
        if let v = registry.value(slot: identifier, code: .cgShadowBlur) { shadowBlur = v }
        if let v = registry.value(slot: identifier, code: .cgShadowOpacity) { shadowOpacity = v }
        if let v = registry.value(slot: identifier, code: .cgRollMode) { rollModePosition = v }
        if let v = registry.value(slot: identifier, code: .cgRollRate) { rollRate = v }
        if let v = registry.value(slot: identifier, code: .cgPeriodPreset) { periodPresetEnabled = v }
        if let v = registry.value(slot: identifier, code: .cgSafeZoneClamp) { safeZoneClampEnabled = v }
    }

    // MARK: - Rendering

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return inputs.first }

        let background: ImageBuffer
        if let input = inputs.first {
            if readbackRenderer == nil { readbackRenderer = OffscreenRenderer(context: metal) }
            guard let renderer = readbackRenderer, let read = renderer.readback(input) else {
                return input
            }
            background = read
        } else {
            // As a SOURCE there is nothing upstream to draw over. Broadcast black —
            // level 16, not 0 — so an untitled CG still measures broadcast-legal.
            background = Self.solid(
                width: renderContext.width, height: renderContext.height,
                level: BroadcastLevels.black)
        }

        // Bypassed, or nothing typed: hand back the plate untouched rather than
        // spend a Core Text pass drawing zero characters.
        guard wetDry > 0.001, !text.isEmpty else {
            return metal.makeTexture(from: background, label: "\(identifier)-plate")
        }

        let image = CharacterGeneratorRenderer.draw(
            text: text, over: background, style: self, renderContext: renderContext)

        var finalImage = image
        if periodPresetEnabled > 0.5, let periodCodec,
           let texture = metal.makeTexture(from: image, label: "\(identifier)-pretext") {
            periodCodec.settings = Self.periodPreset
            if let styled = periodCodec.render(inputs: [texture], context: renderContext) {
                if readbackRenderer == nil { readbackRenderer = OffscreenRenderer(context: metal) }
                if let read = readbackRenderer?.readback(styled) {
                    finalImage = read
                }
            }
        }

        return metal.makeTexture(from: finalImage, label: "\(identifier)-frame")
    }

    /// Headless entry point, for self-QA and for anything that wants pixels without
    /// a Metal device — the same drawing path `render` uses, minus the GPU round trip
    /// and the period preset (which needs a Metal device to run the composite codec).
    public func renderToImage(
        over background: ImageBuffer? = nil,
        context renderContext: RenderContext = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
    ) -> ImageBuffer {
        let plate = background ?? Self.solid(
            width: renderContext.width, height: renderContext.height, level: BroadcastLevels.black)
        guard wetDry > 0.001, !text.isEmpty else { return plate }
        return CharacterGeneratorRenderer.draw(
            text: text, over: plate, style: self, renderContext: renderContext)
    }

    /// The "period" style preset SPEC 18.1 asks for: limited palette and chunky
    /// edges (heavy chroma subsampling and a soft luma bandwidth), a 480-line feel
    /// (composite path rather than S-Video), and slight jitter (a little wobble) —
    /// several generations in, the way a dub of a dub looked.
    static var periodPreset: CompositeSettings {
        CompositeSettings(
            path: .composite,
            subsampling: .quarter411,
            lumaBandwidth: 0.45,
            chromaBleed: 0.6,
            crawl: 0.5,
            wobble: 0.35,
            headSwitching: 0.2,
            generation: 3
        )
    }

    private static func solid(width: Int, height: Int, level: Double) -> ImageBuffer {
        // Bulk-filled. This runs EVERY FRAME when the generator is used as a source
        // with nothing upstream, and per-pixel setPixel spent about 1.5 ms of a
        // 33.4 ms budget painting one colour.
        let byte = UInt8(clamping: Int(level.rounded()))
        return ImageBuffer(width: width, height: height, r: byte, g: byte, b: byte)
    }
}
