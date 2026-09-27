//
//  ScopeRenderer.swift — waveform, parade, histogram and vectorscope (SPEC 19).
//
//  Purpose : The measurement instruments. A picture tells you what it looks like; a
//            scope tells you what it IS, which is the difference between guessing at
//            a signal and knowing it is legal.
//  Inputs  : an `ImageBuffer`.
//  Outputs : an `ImageBuffer` of the scope, graticule and all, ready to draw.
//  Connects: BroadcastSafety for the legal markings; the program monitor's scope tab.
//  Extend  : add a case to `ScopeKind` and a `draw…` function. Keep them returning
//            images: it makes every scope testable by measuring its output, with no
//            window and no GPU.
//
//  These are CPU renderers on a downsampled frame. A scope is a monitoring aid, not
//  part of the signal path, so it does not need to touch every pixel at frame rate —
//  and keeping it off the GPU keeps it out of the render loop's way entirely.
//

import Foundation

/// Which instrument.
public enum ScopeKind: String, CaseIterable, Codable, Sendable {
    /// Luma against horizontal position — the classic waveform monitor.
    case waveform
    /// R, G and B waveforms side by side.
    case parade
    /// Distribution of levels.
    case histogram
    /// Chroma as angle and saturation as radius.
    case vectorscope

    public var displayName: String {
        switch self {
        case .waveform: "Waveform"
        case .parade: "RGB Parade"
        case .histogram: "Histogram"
        case .vectorscope: "Vectorscope"
        }
    }
}

/// How the scopes are shown over the program monitor.
///
/// Cycling in this order is what the scope tab does on each click, ending back at
/// off — so the tab is a single control that reaches every view without a menu.
public enum ScopeDisplayMode: String, CaseIterable, Codable, Sendable {
    case off
    /// A small luma waveform in the corner of the picture.
    ///
    /// FIRST in the cycle, and deliberately so. The usual reason to touch this
    /// control at all is "are my levels sane" — a question a corner-sized waveform
    /// answers without giving up the monitor. Going straight to a full quad meant
    /// trading the picture away to ask it.
    case miniLuma
    /// All four, over the picture.
    case quadOverlay
    case histogram
    case parade
    /// All four, over black — for reading levels without the picture distracting.
    case quadBlack

    public var displayName: String {
        switch self {
        case .off: "Scopes Off"
        case .miniLuma: "Mini Luma"
        case .quadOverlay: "Quad Overlay"
        case .histogram: "Histogram"
        case .parade: "RGB Parade"
        case .quadBlack: "Quad (Blacked Out)"
        }
    }

    /// The next mode in the cycle.
    public var next: ScopeDisplayMode {
        let all = ScopeDisplayMode.allCases
        guard let index = all.firstIndex(of: self) else { return .off }
        return all[(index + 1) % all.count]
    }

    /// Whether the picture shows through behind the scopes.
    public var showsPicture: Bool {
        self == .quadOverlay || self == .miniLuma
    }
}

/// Where a scope sits on the picture.
///
/// Placement is a SEPARATE question from which scopes are showing, which is why it is
/// its own type. The old design fused them — "quad overlay", "quad blacked out",
/// "mini luma" — so choosing a vectorscope in the corner was not expressible at all,
/// and adding it would have meant another case for every combination.
public enum ScopePlacement: String, CaseIterable, Codable, Sendable {
    /// Filling the frame.
    case full
    /// A band across the bottom third, where a lower-third graphic goes.
    case lowerThird
    /// Small, in the lower right, with the picture still the thing you are looking at.
    case corner

    public var displayName: String {
        switch self {
        case .full: "Full"
        case .lowerThird: "Lower Third"
        case .corner: "Corner"
        }
    }

    /// The rectangle it occupies, in 0...1 of the frame, with the origin top left.
    public var rect: (x: Double, y: Double, width: Double, height: Double) {
        switch self {
        case .full: (0, 0, 1, 1)
        // The bottom third exactly, with a small inset at the sides so the trace does
        // not run into the overscan the output path crops.
        case .lowerThird: (0.04, 0.64, 0.92, 0.30)
        case .corner: (0.70, 0.66, 0.28, 0.30)
        }
    }
}

/// Which scopes and data lines are showing, where, and whether they are burned in.
///
/// ── WHY A SET AND NOT A MODE ────────────────────────────────────────────────────
///
/// This replaced a single cycling mode. One button that stepped through five presets
/// meant every combination someone might want had to be anticipated as a preset, and
/// reaching any particular one was a matter of clicking until it came round. Four
/// independent choices — four scopes — is sixteen combinations from four buttons, and
/// each one is one click away.
public struct ScopeSelection: Equatable, Codable, Sendable {

    /// Which instruments are drawn. Empty means the scopes are off.
    public var kinds: Set<ScopeKind> = []

    /// Drawn over the picture, rather than over black.
    ///
    /// Over black is for reading levels without the picture distracting; over the
    /// picture is for watching both at once. Both are useful and neither is a mode of
    /// the other.
    public var isOverlaid: Bool = true

    /// Sits in the lower-third band rather than filling the frame.
    public var isLowerThird: Bool = false

    /// The NAME key: which clip each channel is playing.
    public var showsFileName: Bool = false
    /// The TC key: where each channel's playhead is, as drop-frame timecode.
    public var showsTimecode: Bool = false

    /// DATA BURN: burned into the sub-mix picture, not merely shown on its monitor.
    ///
    /// The scopes and text stop being instruments and become part of the picture, so
    /// they reach air whenever that sub-mix is in the programme mix. Off by default and
    /// deliberately a separate key, because everything else here is a monitoring
    /// choice that cannot affect what an audience sees, and this one can.
    public var isBurnedIn: Bool = false

    public init() {}

    /// Whether any instrument is drawn. Text is `showsData`.
    public var isShowing: Bool { !kinds.isEmpty }

    /// Whether any text line is asked for.
    public var showsData: Bool { showsFileName || showsTimecode }

    /// Whether anything at all is on — the condition DATA BURN needs to mean anything.
    public var hasAnything: Bool { isShowing || showsData }

    /// Where it sits.
    ///
    /// A single scope defaults to the corner and several fill the frame, unless the
    /// lower-third button says otherwise: four instruments crammed into a corner are
    /// unreadable, and one filling the frame hides a picture for no reason.
    public var placement: ScopePlacement {
        if isLowerThird { return .lowerThird }
        return kinds.count == 1 ? .corner : .full
    }

    /// How much the picture behind is held back so the trace stays readable.
    ///
    /// Nothing at all when the scopes are over black — there is no picture to hold
    /// back — and nothing in the corner either, where the scope has its own box and
    /// dimming the whole frame for it would be absurd.
    public var pictureDimming: Double {
        guard isOverlaid else { return 1 }
        return placement == .corner ? 0 : 0.65
    }

    /// The order instruments are laid out in, so the grid is stable as they are
    /// switched on and off.
    ///
    /// Stable order matters more than it sounds: laying them out in set order would
    /// move a scope to a different cell every time a neighbour was toggled, and a
    /// waveform that jumps across the screen when you enable a histogram reads as a
    /// bug.
    public var orderedKinds: [ScopeKind] {
        ScopeKind.allCases.filter { kinds.contains($0) }
    }

    public mutating func toggle(_ kind: ScopeKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }
}

/// Draws scopes.
public enum ScopeRenderer {

    /// How much the source is downsampled before analysis.
    ///
    /// A scope reads the shape of a signal, not individual pixels. Every second pixel
    /// keeps the shape and the trace density while costing a quarter of the work —
    /// and the UI refreshes scopes well below frame rate anyway, so this is not in
    /// the render loop's way.
    public static let sampleStride = 2

    /// Colour of the trace and the graticule.
    private static let traceColor: (r: Double, g: Double, b: Double) = (120, 255, 140)
    private static let graticuleColor: (r: UInt8, g: UInt8, b: UInt8) = (60, 70, 65)
    private static let legalMarkColor: (r: UInt8, g: UInt8, b: UInt8) = (200, 170, 60)

    /// Renders one scope at the given size.
    public static func render(
        _ kind: ScopeKind, from source: ImageBuffer, width: Int, height: Int
    ) -> ImageBuffer {
        switch kind {
        case .waveform: drawWaveform(source, width: width, height: height)
        case .parade: drawParade(source, width: width, height: height)
        case .histogram: drawHistogram(source, width: width, height: height)
        case .vectorscope: drawVectorscope(source, width: width, height: height)
        }
    }

    /// Renders all four in a 2x2, which is the quad view.
    public static func renderQuad(
        from source: ImageBuffer, width: Int, height: Int
    ) -> ImageBuffer {
        var canvas = ImageBuffer(width: width, height: height)
        let halfWidth = width / 2
        let halfHeight = height / 2
        let order: [ScopeKind] = [.waveform, .parade, .histogram, .vectorscope]

        for (index, kind) in order.enumerated() {
            let panel = render(kind, from: source, width: halfWidth, height: halfHeight)
            let originX = (index % 2) * halfWidth
            let originY = (index / 2) * halfHeight
            blit(panel, into: &canvas, atX: originX, y: originY)
        }
        return canvas
    }

    /// Lays the chosen instruments out in one image.
    ///
    /// One fills the canvas, two sit side by side, three or four go in a 2x2. Three
    /// leaves its fourth cell empty rather than stretching one panel to fill it —
    /// scopes are read by shape, and a waveform at a different aspect ratio to the one
    /// beside it is a waveform you have to re-learn every time.
    public static func compose(
        _ selection: ScopeSelection, from source: ImageBuffer, width: Int, height: Int
    ) -> ImageBuffer? {
        let kinds = selection.orderedKinds
        guard !kinds.isEmpty, width > 0, height > 0 else { return nil }

        if kinds.count == 1 {
            return render(kinds[0], from: source, width: width, height: height)
        }

        var canvas = ImageBuffer(width: width, height: height)
        let columns = 2
        let rows = kinds.count <= 2 ? 1 : 2
        let cellWidth = width / columns
        let cellHeight = height / rows

        for (index, kind) in kinds.enumerated() {
            let panel = render(kind, from: source, width: cellWidth, height: cellHeight)
            blit(
                panel, into: &canvas,
                atX: (index % columns) * cellWidth,
                y: (index / columns) * cellHeight)
        }
        return canvas
    }

    // MARK: - Instruments

    /// Luma against column position. Each column of the source becomes a column of
    /// the scope, with brightness showing how many pixels sat at that level.
    private static func drawWaveform(_ source: ImageBuffer, width: Int, height: Int) -> ImageBuffer {
        var scope = ImageBuffer(width: width, height: height)
        drawLumaGraticule(into: &scope)

        for x in 0..<width {
            // Map this scope column onto a source column.
            let sourceX = x * source.width / max(width, 1)
            for y in stride(from: 0, to: source.height, by: sampleStride) {
                guard sourceX < source.width else { continue }
                let pixel = source.pixel(x: sourceX, y: y)
                let luma = 0.299 * Double(pixel.r) + 0.587 * Double(pixel.g) + 0.114 * Double(pixel.b)
                // Level runs up the scope: 0 at the bottom, 255 at the top.
                let plotY = height - 1 - Int(luma / 255.0 * Double(height - 1))
                accumulate(into: &scope, x: x, y: plotY, colour: traceColor)
            }
        }
        return scope
    }

    /// Three waveforms side by side, one per channel.
    private static func drawParade(_ source: ImageBuffer, width: Int, height: Int) -> ImageBuffer {
        var scope = ImageBuffer(width: width, height: height)
        drawLumaGraticule(into: &scope)

        let panelWidth = width / 3
        let channelColours: [(r: Double, g: Double, b: Double)] = [
            (255, 80, 80), (80, 255, 80), (90, 120, 255)
        ]

        for channel in 0..<3 {
            for x in 0..<panelWidth {
                let sourceX = x * source.width / max(panelWidth, 1)
                guard sourceX < source.width else { continue }
                for y in stride(from: 0, to: source.height, by: sampleStride) {
                    let pixel = source.pixel(x: sourceX, y: y)
                    let value: UInt8
                    switch channel {
                    case 0: value = pixel.r
                    case 1: value = pixel.g
                    default: value = pixel.b
                    }
                    let plotY = height - 1 - Int(Double(value) / 255.0 * Double(height - 1))
                    accumulate(
                        into: &scope, x: channel * panelWidth + x, y: plotY,
                        colour: channelColours[channel])
                }
            }
        }
        return scope
    }

    /// How many pixels sit at each level, per channel.
    private static func drawHistogram(_ source: ImageBuffer, width: Int, height: Int) -> ImageBuffer {
        var scope = ImageBuffer(width: width, height: height)

        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)

        for y in stride(from: 0, to: source.height, by: sampleStride) {
            for x in stride(from: 0, to: source.width, by: sampleStride) {
                let pixel = source.pixel(x: x, y: y)
                red[Int(pixel.r)] += 1
                green[Int(pixel.g)] += 1
                blue[Int(pixel.b)] += 1
            }
        }

        // Scale to the tallest bin so the shape fills the box whatever the content.
        let peak = max(red.max() ?? 1, max(green.max() ?? 1, blue.max() ?? 1))
        guard peak > 0 else { return scope }

        drawLevelGraticule(into: &scope)

        for bin in 0..<256 {
            let x = bin * (width - 1) / 255
            for (counts, colour) in [
                (red, (r: 255.0, g: 70.0, b: 70.0)),
                (green, (r: 70.0, g: 255.0, b: 70.0)),
                (blue, (r: 90.0, g: 110.0, b: 255.0))
            ] {
                let barHeight = Int(Double(counts[bin]) / Double(peak) * Double(height - 1))
                guard barHeight > 0 else { continue }
                for y in (height - 1 - barHeight)..<height {
                    accumulate(into: &scope, x: x, y: y, colour: colour, weight: 0.45)
                }
                // Widen each bin to the next one's position, so a 256-bin histogram
                // drawn into a box narrower than 256 px has no gaps between bars.
                let nextX = min((bin + 1) * (width - 1) / 255, width - 1)
                if nextX > x + 1 {
                    for fill in (x + 1)..<nextX {
                        for y in (height - 1 - barHeight)..<height {
                            accumulate(into: &scope, x: fill, y: y, colour: colour, weight: 0.45)
                        }
                    }
                }
            }
        }
        return scope
    }

    /// Chroma plotted as angle (hue) and radius (saturation).
    private static func drawVectorscope(_ source: ImageBuffer, width: Int, height: Int) -> ImageBuffer {
        var scope = ImageBuffer(width: width, height: height)

        let centreX = width / 2
        let centreY = height / 2
        let radius = Double(min(width, height)) / 2 - 2

        // Graticule: the outer circle is 100% saturation, the inner one 75% — where
        // colour bars should land on a correctly set up signal.
        drawCircle(into: &scope, centreX: centreX, centreY: centreY,
                   radius: radius, colour: graticuleColor)
        drawCircle(into: &scope, centreX: centreX, centreY: centreY,
                   radius: radius * 0.75, colour: legalMarkColor)

        for y in stride(from: 0, to: source.height, by: sampleStride) {
            for x in stride(from: 0, to: source.width, by: sampleStride) {
                let pixel = source.pixel(x: x, y: y)
                let r = Double(pixel.r)
                let g = Double(pixel.g)
                let b = Double(pixel.b)
                // The same YIQ the composite codec uses, so what the vectorscope
                // shows and what the encoder does agree.
                let i = 0.596 * r - 0.274 * g - 0.322 * b
                let q = 0.211 * r - 0.523 * g + 0.312 * b

                // I and Q run about -152...152 at full saturation.
                let plotX = centreX + Int(i / 152.0 * radius)
                let plotY = centreY - Int(q / 152.0 * radius)
                // A vectorscope's points cluster tightly — a flat colour is a single
                // dot. Drawing a small cross rather than one pixel is what makes those
                // dots findable, which is the whole reason to look at one.
                accumulate(into: &scope, x: plotX, y: plotY, colour: traceColor, weight: 0.8)
                accumulate(into: &scope, x: plotX + 1, y: plotY, colour: traceColor, weight: 0.4)
                accumulate(into: &scope, x: plotX - 1, y: plotY, colour: traceColor, weight: 0.4)
                accumulate(into: &scope, x: plotX, y: plotY + 1, colour: traceColor, weight: 0.4)
                accumulate(into: &scope, x: plotX, y: plotY - 1, colour: traceColor, weight: 0.4)
            }
        }
        return scope
    }

    // MARK: - Graticules

    /// Horizontal lines at the NTSC legal levels, so illegal signal is visible as
    /// trace outside the marked band rather than as a number to interpret.
    private static func drawLumaGraticule(into scope: inout ImageBuffer) {
        let height = scope.height
        for level in [0.0, BroadcastLevels.black, 128.0, BroadcastLevels.white, 255.0] {
            let y = height - 1 - Int(level / 255.0 * Double(height - 1))
            guard y >= 0, y < height else { continue }
            let isLegalMark = (level == BroadcastLevels.black || level == BroadcastLevels.white)
            let colour = isLegalMark ? legalMarkColor : graticuleColor
            for x in 0..<scope.width {
                scope.setPixel(x: x, y: y, r: colour.r, g: colour.g, b: colour.b)
            }
        }
    }

    /// Vertical lines at the legal levels, for the histogram's horizontal axis.
    private static func drawLevelGraticule(into scope: inout ImageBuffer) {
        for level in [BroadcastLevels.black, BroadcastLevels.white] {
            let x = Int(level / 255.0 * Double(scope.width - 1))
            guard x >= 0, x < scope.width else { continue }
            for y in 0..<scope.height {
                scope.setPixel(x: x, y: y,
                               r: legalMarkColor.r, g: legalMarkColor.g, b: legalMarkColor.b)
            }
        }
    }

    private static func drawCircle(
        into scope: inout ImageBuffer, centreX: Int, centreY: Int, radius: Double,
        colour: (r: UInt8, g: UInt8, b: UInt8)
    ) {
        guard radius > 1 else { return }
        let steps = Int(radius * 8)
        for step in 0..<steps {
            let angle = Double(step) / Double(steps) * 2 * Double.pi
            let x = centreX + Int(cos(angle) * radius)
            let y = centreY + Int(sin(angle) * radius)
            guard x >= 0, x < scope.width, y >= 0, y < scope.height else { continue }
            scope.setPixel(x: x, y: y, r: colour.r, g: colour.g, b: colour.b)
        }
    }

    // MARK: - Plotting

    /// Adds light at a point, so overlapping samples build up as they do on a real
    /// scope's phosphor rather than each one replacing the last.
    private static func accumulate(
        into scope: inout ImageBuffer, x: Int, y: Int,
        colour: (r: Double, g: Double, b: Double), weight: Double = 0.55
    ) {
        guard x >= 0, x < scope.width, y >= 0, y < scope.height else { return }
        let existing = scope.pixel(x: x, y: y)
        scope.setPixel(
            x: x, y: y,
            r: UInt8(min(Double(existing.r) + colour.r * weight, 255)),
            g: UInt8(min(Double(existing.g) + colour.g * weight, 255)),
            b: UInt8(min(Double(existing.b) + colour.b * weight, 255))
        )
    }

    /// Copies one image into another at an offset.
    private static func blit(_ source: ImageBuffer, into destination: inout ImageBuffer, atX: Int, y originY: Int) {
        for row in 0..<source.height {
            let targetY = originY + row
            guard targetY >= 0, targetY < destination.height else { continue }
            for column in 0..<source.width {
                let targetX = atX + column
                guard targetX >= 0, targetX < destination.width else { continue }
                let pixel = source.pixel(x: column, y: row)
                destination.setPixel(x: targetX, y: targetY,
                                     r: pixel.r, g: pixel.g, b: pixel.b)
            }
        }
    }
}
