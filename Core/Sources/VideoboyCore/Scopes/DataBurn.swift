//
//  DataBurn.swift — the text half of DATA BURN: file names and timecode.
//
//  Purpose : The scope keys can burn instruments into a sub-mix; NAME and TC add
//            text beside them — which clip each channel is playing, and where in it.
//            This file is everything about that text that is not Metal: the
//            timecode maths, the style the Preferences window edits, which lines to
//            show for a set of channels, and drawing those lines into a small image.
//  Inputs  : per-channel entries (label, file name, playhead frame, whether the fader
//            lets it through), a `DataBurnStyle`, the height of the frame it lands on.
//  Outputs : strings, and a premultiplied RGBA `ImageBuffer` of just the text block.
//  Connects: ScopeOverlayNode (burns the image into a sub-mix), MetalPreviewView (shows
//            the same image on a monitor), Preferences (stores the style),
//            ShellController (builds the entries from the engine).
//  Extend  : a new field (say, the clip's loop mode) is one more optional on
//            `DataBurnEntry` and one more clause in `DataBurnText.line`. Keep drawing
//            here, and keep this free of AppKit so it stays testable headlessly.
//
//  ── WHY A SMALL IMAGE, NOT A FULL FRAME ─────────────────────────────────────────
//
//  Timecode changes every frame while a clip plays, so this is drawn up to 30 times a
//  second. Drawing only the text block (a few hundred pixels square) instead of a
//  720x480 plate keeps both the Core Text pass and the upload trivially small, which
//  is what keeps a ticking burn-in off the frame budget.
//

import CoreGraphics
import CoreText
import Foundation

// MARK: - Timecode

/// SMPTE timecode for the app's content rate.
public enum Timecode {

    /// Frames in ten minutes of 29.97 drop-frame: ten minutes of 30 fps, less two
    /// frame numbers in each of the nine minutes not divisible by ten.
    private static let framesPerTenMinutes = 17_982
    /// Frames in each minute that drops two numbers.
    private static let framesPerDroppedMinute = 1_798
    private static let nominalRate = 30

    /// `HH:MM:SS;FF` for a frame count at 29.97, drop-frame.
    ///
    /// Drop-frame because the graph runs at 29.97 and a non-drop count drifts 3.6 s an
    /// hour behind the wall clock — a clip's timecode should read as its real length.
    /// The semicolon is the standard mark that a timecode is drop-frame.
    public static func dropFrame(frame: Int) -> String {
        let frame = max(frame, 0)
        let tens = frame / framesPerTenMinutes
        let remainder = frame % framesPerTenMinutes
        // The first minute of each ten keeps all its numbers; each later one skips two.
        let skipped = remainder > 1 ? 2 * ((remainder - 2) / framesPerDroppedMinute) : 0
        let numbered = frame + 18 * tens + skipped

        let frames = numbered % nominalRate
        let seconds = (numbered / nominalRate) % 60
        let minutes = (numbered / (nominalRate * 60)) % 60
        let hours = (numbered / (nominalRate * 3600)) % 24
        return String(format: "%02d:%02d:%02d;%02d", hours, minutes, seconds, frames)
    }
}

// MARK: - Style

/// How the burned-in text looks. Edited in Preferences → Outputs.
public struct DataBurnStyle: Codable, Equatable, Sendable {

    /// What sits behind the letters so they read over any picture.
    public enum Backing: String, CaseIterable, Codable, Sendable {
        case none
        case shadow
        case outline
        case box

        public var displayName: String {
            switch self {
            case .none: "None"
            case .shadow: "Shadow"
            case .outline: "Outline"
            case .box: "Box"
            }
        }
    }

    /// A font family name, as Font Book lists it.
    public var fontFamily: String = "Menlo"
    /// Letter size in pixels of a 480-line frame. Scaled for any other frame height.
    public var pixelSize: Double = 16
    public var isBold: Bool = true
    public var colour: TitlerColor = .white
    public var backing: Backing = .box

    /// The sizes the Preferences window offers.
    public static let pixelSizes: [Double] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 40]

    public init() {}

    // Lenient, like `Preferences`: a missing or unreadable field keeps its default
    // instead of throwing away the whole style.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        self.init()
        fontFamily = decode(.fontFamily, fontFamily)
        pixelSize = decode(.pixelSize, pixelSize)
        isBold = decode(.isBold, isBold)
        colour = decode(.colour, colour)
        backing = decode(.backing, backing)
    }
}

/// Which corner of the picture a text block sits in.
///
/// Sub Mix 1 and Sub Mix 2 burn into opposite corners so that, while PROGRAM is
/// crossfading between them, the two blocks never land on top of each other.
public enum DataBurnAnchor: Sendable {
    case topLeft
    case topCentre
    case topRight

    /// Distance from the frame edge, as a fraction of it. Inside title-safe, so an
    /// analog monitor's overscan does not eat the first characters.
    static let marginX = 0.08
    static let marginY = 0.07

    /// Where a block `width` wide (0...1 of the frame) starts.
    func originX(forWidth width: Double) -> Double {
        switch self {
        case .topLeft: Self.marginX
        case .topCentre: 0.5 - width / 2
        case .topRight: 1 - Self.marginX - width
        }
    }
}

// MARK: - Lines

/// One channel's worth of information.
public struct DataBurnEntry: Equatable, Sendable {
    /// "A", "S1" — what the line starts with.
    public var label: String
    /// The clip's file name, or a live source's name. Nil for an empty channel.
    public var name: String?
    /// The playhead, in frames. Nil for a live source, which has no position.
    public var frame: Int?
    /// False when its fader shuts it out entirely. The line stays, blank after the
    /// label, so the block does not jump about as the fader moves.
    public var isOnAir: Bool

    public init(label: String, name: String?, frame: Int?, isOnAir: Bool) {
        self.label = label
        self.name = name
        self.frame = frame
        self.isOnAir = isOnAir
    }
}

/// Turns entries into the lines that get drawn.
public enum DataBurnText {

    /// File names longer than this are shortened in the middle, keeping the start and
    /// the extension — the two parts a person actually recognises.
    public static let nameLimit = 28

    /// The fader within this of an end counts as AT that end. Matches the one-way
    /// latch in `CrossfadeNode`.
    static let faderEndTolerance = 0.005

    /// Whether one side of a two-input crossfade is reaching the output.
    ///
    /// Position 0 is all of input 0, position 1 all of input 1.
    public static func isOnAir(input index: Int, position: Double) -> Bool {
        index == 0 ? position < 1 - faderEndTolerance : position > faderEndTolerance
    }

    /// One line per entry, or none when neither field is asked for.
    public static func lines(
        _ entries: [DataBurnEntry], showsName: Bool, showsTimecode: Bool
    ) -> [String] {
        guard showsName || showsTimecode else { return [] }
        return entries.map { line($0, showsName: showsName, showsTimecode: showsTimecode) }
    }

    static func line(_ entry: DataBurnEntry, showsName: Bool, showsTimecode: Bool) -> String {
        var parts = ["\(entry.label):"]
        guard entry.isOnAir else { return parts[0] }
        if showsName, let name = entry.name { parts.append(shortened(name)) }
        if showsTimecode, let frame = entry.frame { parts.append(Timecode.dropFrame(frame: frame)) }
        return parts.joined(separator: " ")
    }

    /// `a_very_long_clip_name_from_the_camera.dv` → `a_very_long_cl…_camera.dv`.
    public static func shortened(_ name: String, limit: Int = nameLimit) -> String {
        guard name.count > limit, limit > 3 else { return name }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }
}

// MARK: - Drawing

/// Draws a block of lines in a `DataBurnStyle`.
public enum DataBurnRenderer {

    /// The frame height `DataBurnStyle.pixelSize` is measured against.
    public static let referenceFrameHeight = 480.0

    /// Opacity of the `.box` backing — dark enough to read white over white, light
    /// enough to see the picture move behind it.
    static let boxOpacity: CGFloat = 0.6

    /// Draws `lines` for a frame `frameHeight` lines tall.
    ///
    /// Returns just the text block, premultiplied RGBA, with transparent pixels where
    /// there is no text or backing. Nil when there is nothing to draw.
    public static func render(
        lines: [String], style: DataBurnStyle, frameHeight: Int
    ) -> ImageBuffer? {
        guard !lines.isEmpty, frameHeight > 0 else { return nil }
        let scale = Double(frameHeight) / referenceFrameHeight
        let fontSize = CGFloat(max(style.pixelSize, 4) * scale)
        let font = makeFont(style: style, size: fontSize)

        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: style.colour.cgColor
        ]
        if style.backing == .outline {
            // Negative means fill AND stroke; positive would hollow the letters out.
            attributes[kCTStrokeWidthAttributeName] = -4.0
            attributes[kCTStrokeColorAttributeName] = TitlerColor.black.cgColor
        }

        let ctLines = lines.map { text in
            CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ceil(ascent + descent + CTFontGetLeading(font))
        let padding = ceil(fontSize * 0.35)
        let widest = ctLines
            .map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
            .max() ?? 0

        let width = Int(ceil(widest + padding * 2))
        let height = Int(lineHeight * CGFloat(lines.count) + padding * 2)
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        var drew = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * ImageBuffer.bytesPerPixel,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }

            if style.backing == .box {
                context.setFillColor(TitlerColor.black.cgColor.copy(alpha: boxOpacity)
                    ?? TitlerColor.black.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            if style.backing == .shadow {
                // Down and right, in a bottom-up context, hence the negative y.
                context.setShadow(
                    offset: CGSize(width: 1.5 * scale, height: -1.5 * scale),
                    blur: 2 * scale,
                    color: TitlerColor.black.cgColor)
            }

            // Lines run top-down; CoreGraphics runs bottom-up, so each baseline is
            // measured from the top and then flipped.
            for (index, line) in ctLines.enumerated() {
                let baselineFromTop = padding + lineHeight * CGFloat(index) + ascent
                context.textPosition = CGPoint(x: padding, y: CGFloat(height) - baselineFromTop)
                CTLineDraw(line, context)
            }
            drew = true
        }
        guard drew else {
            Log.error(.render, "data burn could not create a drawing context")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Where a block drawn by `render` sits, in 0...1 of the frame, origin top left.
    ///
    /// Snapped to whole pixels of the frame so the text is sampled 1:1 — a half-pixel
    /// offset would soften every letter.
    public static func rect(
        for image: ImageBuffer, anchor: DataBurnAnchor, frameWidth: Int, frameHeight: Int
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let fw = Double(max(frameWidth, 1))
        let fh = Double(max(frameHeight, 1))
        let width = Double(image.width) / fw
        let height = Double(image.height) / fh
        let x = (anchor.originX(forWidth: width) * fw).rounded() / fw
        let y = (DataBurnAnchor.marginY * fh).rounded() / fh
        return (x, y, width, height)
    }

    /// The chosen family at `size`, bold if asked, with tabular digits so a ticking
    /// timecode does not shuffle sideways in a proportional font.
    private static func makeFont(style: DataBurnStyle, size: CGFloat) -> CTFont {
        let numberSpacing: [CFString: Any] = [
            kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: style.fontFamily,
            kCTFontFeatureSettingsAttribute: [numberSpacing]
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        guard style.isBold else { return font }
        return CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
    }
}
