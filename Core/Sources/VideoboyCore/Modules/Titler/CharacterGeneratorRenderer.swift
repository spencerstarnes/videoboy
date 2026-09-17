//
//  CharacterGeneratorRenderer.swift — the actual Core Text drawing pass.
//
//  Purpose : Split out of `CharacterGeneratorNode` so the graph-node plumbing (param
//            codes, applyParameters, the source/overlay branch) and the drawing
//            itself are two things you can read without the other getting in the
//            way. Everything here is pure: an `ImageBuffer` background and a style
//            in, a new `ImageBuffer` out. No Metal, no registry, easy to unit-test.
//  Inputs  : text, a style (the node itself, read-only), a background plate, and
//            frame timing for roll/crawl motion.
//  Outputs : an `ImageBuffer` the same size as the background, with type drawn on it.
//  Connects: CharacterGeneratorNode (the only caller), CRTGeometry (title-safe
//            placement), CoreText (layout and drawing).
//  Extend  : a new drawing detail (a second stroke pass, a glow) is a few more lines
//            in `draw(text:over:style:renderContext:)`, not a new file — this one
//            stays a single pass over a single `CGContext`.
//

import CoreText
import CoreGraphics
import Foundation

enum CharacterGeneratorRenderer {

    /// Draws `text` over `background` per `style`, and returns the composited image.
    static func draw(
        text: String,
        over background: ImageBuffer,
        style node: CharacterGeneratorNode,
        renderContext: RenderContext
    ) -> ImageBuffer {
        let width = background.width
        let height = background.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Lay the text out FIRST. None of this needs the bitmap, and keeping it out
        // here leaves the closure below holding only the one thing that genuinely
        // has to happen while the buffer pointer is valid: the drawing itself.
        let attributed = makeAttributedString(text: text, style: node)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        // Measure before placing, so vertical anchoring (position 0.5 means the
        // text block's own centre, not its top-left corner) is right regardless of
        // how many lines were typed.
        let measureSize = CGSize(width: CGFloat(width) * 2, height: .greatestFiniteMagnitude)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, measureSize, nil)

        var origin = anchorOrigin(
            for: fitted, node: node, frameWidth: width, frameHeight: height)

        if node.safeZoneClampEnabled > 0.5 {
            origin = clampToTitleSafe(origin: origin, size: fitted, frameWidth: width, frameHeight: height)
        }

        origin = applyRollMotion(
            to: origin, size: fitted, node: node, renderContext: renderContext,
            frameWidth: width, frameHeight: height)

        // One conversion, in one place, from the top-down coordinates every
        // placement function above works in (which is how safe zones and every
        // other geometry value in this app read) to CoreGraphics' bottom-up bitmap
        // space. Flipping the CTM instead is the obvious-looking alternative and it
        // is wrong: it mirrors the glyphs themselves.
        let drawOrigin = CGPoint(x: origin.x, y: CGFloat(height) - origin.y - fitted.height)

        // The frame path is exactly as wide as the text, so paragraph alignment
        // positions lines RELATIVE TO EACH OTHER within the block while
        // `anchorOrigin` above decides where the block itself sits. A wider path
        // would fight it — centred text would centre in the path, not on the
        // position the operator set. (Justified consequently behaves as left within
        // the block, since there is no slack in a text-width path to justify into.)
        let textRect = CGRect(
            origin: drawOrigin,
            size: CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2))
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: CFAttributedStringGetLength(attributed)), path, nil)

        var pixels = background.pixels
        var drew = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let cgContext = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * ImageBuffer.bytesPerPixel,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }

            cgContext.setAlpha(CGFloat(max(0, min(1, node.opacity)) * max(0, min(1, node.wetDry))))

            if node.shadowBlur > 0.001 || node.shadowOffsetX != 0 || node.shadowOffsetY != 0 {
                // Negated because the context is bottom-up but the control is not:
                // a positive shadow Y means DOWN, the way it does in every other
                // titler an operator has used.
                cgContext.setShadow(
                    offset: CGSize(width: node.shadowOffsetX, height: -node.shadowOffsetY),
                    blur: CGFloat(node.shadowBlur),
                    color: node.shadowColor.cgColor.copy(alpha: node.shadowOpacity)
                )
            }

            CTFrameDraw(frame, cgContext)
            drew = true
        }

        guard drew else {
            Log.error(.titler, "\(node.identifier) could not create a drawing context; returning the plate unmarked")
            return background
        }

        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    // MARK: - Attributed string

    private static func makeAttributedString(
        text: String, style node: CharacterGeneratorNode
    ) -> CFAttributedString {
        let font = makeFont(style: node)

        let paragraph = makeParagraphStyle(style: node)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: node.fillColor.cgColor,
            kCTParagraphStyleAttributeName: paragraph
        ]

        // See the file header on `CharacterGeneratorNode`: kerning-enabled and
        // tracking are two SPEC-level controls collapsing onto CoreText's one
        // overloaded attribute. 0 means "no kerning at all"; omitting the key means
        // "the font's own pair kerning, no extra tracking"; any other value means
        // "pair kerning plus this many points of uniform tracking".
        if node.kerningEnabled <= 0.5 {
            attributes[kCTKernAttributeName] = 0.0
        } else if abs(node.tracking) > 0.001 {
            attributes[kCTKernAttributeName] = node.tracking
        }

        if node.outlineWidth > 0.001 {
            attributes[kCTStrokeWidthAttributeName] = node.outlineWidth
            attributes[kCTStrokeColorAttributeName] = node.outlineColor.cgColor
            // A negative value tells CoreText to both fill AND stroke a glyph.
            // Positive values mean stroke-only (an outline with a hollow centre),
            // which is what "outline" would mean everywhere else if taken literally
            // — but a title with no fill inside its outline reads as broken, not
            // stylish, so this always keeps the fill.
        }

        let cfString = text as CFString
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), cfString)
        CFAttributedStringSetAttributes(
            attributed, CFRange(location: 0, length: CFAttributedStringGetLength(attributed)),
            attributes as CFDictionary, false)

        // The stroke-plus-fill trick above needs the width negated after the other
        // attributes are set, since CFAttributedStringSetAttributes above just wrote
        // the positive value used for the outline pass's line thickness.
        if node.outlineWidth > 0.001 {
            let negative = -node.outlineWidth
            CFAttributedStringSetAttribute(
                attributed, CFRange(location: 0, length: CFAttributedStringGetLength(attributed)),
                kCTStrokeWidthAttributeName, negative as CFNumber)
        }

        return attributed
    }

    private static func makeFont(style node: CharacterGeneratorNode) -> CTFont {
        // Scale multiplies the point size rather than transforming the context.
        // That way the measured layout already accounts for it and placement needs
        // no second opinion about how big the text ended up.
        let pointSize = CGFloat(node.fontSize * max(node.scale, 0.01))
        let baseDescriptor = CTFontDescriptorCreateWithNameAndSize(
            node.fontFamily as CFString, pointSize)

        let weight = TitlerWeight.from(normalised: node.fontWeightPosition)
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight.ctWeight]
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let weighted = CTFontDescriptorCreateCopyWithAttributes(
            baseDescriptor, attributes as CFDictionary)

        return CTFontCreateWithFontDescriptor(weighted, pointSize, nil)
    }

    private static func makeParagraphStyle(style node: CharacterGeneratorNode) -> CTParagraphStyle {
        var alignment = TitlerAlignment.from(normalised: node.alignmentPosition).ctAlignment
        var lineSpacing = Float(node.leading)

        // The pointers must OUTLIVE the CTParagraphStyleCreate call, which is why
        // this is nested rather than a flat array of settings.
        //
        // `CTParagraphStyleSetting(value: &x)` does not copy what x points at — it
        // keeps the pointer, and CoreText dereferences it later, inside Create. An
        // `&x` argument is only guaranteed valid for the duration of the call it is
        // passed to, so by the time Create read them both pointers had expired and
        // the alignment and the leading were whatever that memory happened to hold.
        // It usually held the right thing, which is exactly what makes this class of
        // bug dangerous: the tests passed.
        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineSpacing) { spacingPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer),
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment,
                        valueSize: MemoryLayout<Float>.size,
                        value: spacingPointer)
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    // MARK: - Placement

    /// Where the text's top-left corner goes so that `node.positionX/Y` land on the
    /// point the alignment implies — the centre of the text block for `.center`
    /// alignment, its left edge for `.left`, and so on. This is what makes
    /// "position IS the anchor" (see the node's file header) actually true rather
    /// than merely documented.
    private static func anchorOrigin(
        for size: CGSize, node: CharacterGeneratorNode, frameWidth: Int, frameHeight: Int
    ) -> CGPoint {
        // `size` is already the scaled layout — see `makeFont`, which folds scale
        // into the point size — so it must NOT be multiplied by scale again here.
        let scaledWidth = size.width
        let scaledHeight = size.height

        let targetX = CGFloat(node.positionX) * CGFloat(frameWidth)
        let targetY = CGFloat(node.positionY) * CGFloat(frameHeight)

        let alignment = TitlerAlignment.from(normalised: node.alignmentPosition)
        let x: CGFloat
        switch alignment {
        case .left: x = targetX
        case .center, .justified: x = targetX - scaledWidth / 2
        case .right: x = targetX - scaledWidth
        }
        // Vertically, position always anchors the text block's own centre — SPEC
        // does not ask for a separate vertical alignment, only "position/anchor".
        let y = targetY - scaledHeight / 2
        return CGPoint(x: x, y: y)
    }

    /// Pulls the text back inside the title-safe rectangle (SPEC 11) when the clamp
    /// is on, so text cannot be placed somewhere a CRT's overscan would cut off.
    private static func clampToTitleSafe(
        origin: CGPoint, size: CGSize, frameWidth: Int, frameHeight: Int
    ) -> CGPoint {
        let safe = CRTGeometry.titleSafe.inPixels(width: frameWidth, height: frameHeight)
        let minX = CGFloat(safe.x)
        let maxX = CGFloat(safe.x + safe.width) - size.width
        let minY = CGFloat(safe.y)
        let maxY = CGFloat(safe.y + safe.height) - size.height

        // If the text is wider or taller than the safe area itself, clamping would
        // invert the range (min > max) and produce nonsense — in that case centre it
        // instead of fighting the arithmetic. A title that does not fit is a
        // composition problem for the operator to see and fix, not one this
        // function should hide by moving it somewhere arbitrary.
        let x = maxX >= minX ? min(max(origin.x, minX), maxX) : CGFloat(safe.x) + (CGFloat(safe.width) - size.width) / 2
        let y = maxY >= minY ? min(max(origin.y, minY), maxY) : CGFloat(safe.y) + (CGFloat(safe.height) - size.height) / 2
        return CGPoint(x: x, y: y)
    }

    /// Slides the text for roll (upward) or crawl (sideways) motion. Locked to the
    /// musical clock when it is running — `totalBeats` divided into bars — and
    /// falling back to wall-clock time when it is not, so a rolling credit still
    /// rolls with nothing playing (SPEC 18.1 says clock-SYNCABLE, not
    /// clock-dependent).
    private static func applyRollMotion(
        to origin: CGPoint, size: CGSize, node: CharacterGeneratorNode,
        renderContext: RenderContext, frameWidth: Int, frameHeight: Int
    ) -> CGPoint {
        let mode = TitlerRollMode.from(normalised: node.rollModePosition)
        guard mode == .roll || mode == .crawl else { return origin }

        // Bars elapsed, as a continuous value. Four beats to a bar is this app's one
        // fixed musical grid (SPEC 4), so a roll rate is expressed in bars the same
        // way step timing is. With no transport running, a "bar" is two seconds —
        // 120bpm — so a credit roll still rolls with nothing playing.
        let bars: Double
        if let position = renderContext.musicalPosition {
            bars = position.totalBeats / 4.0
        } else {
            bars = renderContext.presentationTime / 2.0
        }

        switch mode {
        case .roll:
            // rollRate is SCREEN-HEIGHTS per bar, so it becomes pixels by way of the
            // frame height. Using the rate directly as a pixel count is the bug this
            // replaced: it moved the type one pixel per bar and parked it off-frame.
            let travel = bars * node.rollRate * Double(frameHeight)
            let span = Double(frameHeight) + Double(size.height)
            let advanced = wrapped(travel, span: span)
            // Starts just below the frame and climbs out of the top, then repeats —
            // a credit roll that has finished is not left sitting mid-screen.
            // Vertical position is the roll itself here, so positionY does not also
            // get a say; positionX still places the column.
            return CGPoint(x: origin.x, y: CGFloat(Double(frameHeight) - advanced))
        case .crawl:
            let travel = bars * node.rollRate * Double(frameWidth)
            let span = Double(frameWidth) + Double(size.width)
            let advanced = wrapped(travel, span: span)
            // Enters from the right and leaves at the left, ticker-fashion, holding
            // whatever vertical position was set.
            return CGPoint(x: CGFloat(Double(frameWidth) - advanced), y: origin.y)
        default:
            return origin
        }
    }

    /// `travel` folded into 0..<span, staying positive for negative rates so a
    /// reversed roll wraps rather than flying off in the wrong direction.
    private static func wrapped(_ travel: Double, span: Double) -> Double {
        guard span > 0 else { return 0 }
        let raw = travel.truncatingRemainder(dividingBy: span)
        return raw < 0 ? raw + span : raw
    }
}
