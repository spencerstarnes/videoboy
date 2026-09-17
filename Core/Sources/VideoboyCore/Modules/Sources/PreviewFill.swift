//
//  PreviewFill.swift — how a picture sits inside a frame that is not its shape.
//
//  Purpose : Source material is not all 4:3. A 16:9 clip in a 4:3 window has to do
//            something, and there are only four honest answers — show it all, fill
//            the frame, distort it, or leave it alone. Naming them the way the rest
//            of the industry does means nobody has to guess which is which.
//  Inputs  : the source's aspect ratio and the frame's.
//  Outputs : the rectangle the picture should occupy.
//  Connects: MetalPreviewView, the output window, Preferences.
//  Extend  : there is no fifth answer. Anything else is one of these four with a
//            crop rectangle, which is a different feature.
//
//  The names follow AVFoundation's video gravity and CSS's object-fit, which agree
//  with each other:
//
//      fit      AVLayerVideoGravity.resizeAspect      object-fit: contain
//      fill     AVLayerVideoGravity.resizeAspectFill  object-fit: cover
//      stretch  AVLayerVideoGravity.resize            object-fit: fill
//      centre   (no equivalent gravity)               object-fit: none
//

import Foundation

/// How a picture is placed inside a frame of a different shape.
public enum PreviewFill: String, CaseIterable, Codable, Sendable {
    /// The whole picture is visible, with bars where the shapes disagree.
    case fit
    /// The frame is filled and the overflow is cropped away.
    case fill
    /// The frame is filled by distorting the picture.
    case stretch
    /// Native size, centred, neither scaled up nor down.
    case centre

    public var displayName: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        case .centre: "Centre"
        }
    }

    public var explanation: String {
        switch self {
        case .fit: "Show the whole picture, with bars where the shapes differ."
        case .fill: "Fill the frame and crop what does not fit."
        case .stretch: "Fill the frame by distorting the picture."
        case .centre: "Native size, centred, not scaled."
        }
    }

    /// Where a picture of `sourceSize` goes inside `frame`.
    ///
    /// - Returns: a rectangle in `frame`'s coordinates. It can extend beyond the
    ///   frame for `.fill` and `.centre`, and the caller is expected to clip — the
    ///   overflow is the point of those two, not an error.
    public func rect(sourceSize: CGSize, in frame: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: frame)
        }

        let size: CGSize
        switch self {
        case .stretch:
            size = frame
        case .centre:
            size = sourceSize
        case .fit, .fill:
            let sourceAspect = sourceSize.width / sourceSize.height
            let frameAspect = frame.width / frame.height
            // Fit takes the smaller scale so nothing is lost; fill takes the larger
            // so nothing is empty. That one comparison is the whole difference.
            let widthLed = self == .fit ? (sourceAspect > frameAspect) : (sourceAspect < frameAspect)
            size = widthLed
                ? CGSize(width: frame.width, height: frame.width / sourceAspect)
                : CGSize(width: frame.height * sourceAspect, height: frame.height)
        }

        return CGRect(
            x: (frame.width - size.width) / 2,
            y: (frame.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}
