//
//  TestPatternSourceNode.swift — test patterns as a first-class source (SPEC 11).
//
//  Purpose : A test pattern must be available both as a source you can assign to a
//            channel and as something you can send straight to a display to line up
//            a CRT. This is that source.
//  Inputs  : which pattern to generate.
//  Outputs : one texture.
//  Connects: TestPattern (the pixels), the Asset Browser, the output router.
//  Extend  : add a case to `Kind` and a branch in `makeImage`.
//

import Foundation
import Metal

/// Generates a static test pattern.
public final class TestPatternSourceNode: Node {

    /// Which pattern.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case colorBars75
        case whiteField
        case blackField
        case crosshatch
        case pluge
        case grayscaleRamp

        /// Name shown in the UI.
        public var displayName: String {
            switch self {
            case .colorBars75: "75% Colour Bars"
            case .whiteField: "100% White Field"
            case .blackField: "Black Field"
            case .crosshatch: "Crosshatch"
            case .pluge: "PLUGE"
            case .grayscaleRamp: "Greyscale Ramp"
            }
        }
    }

    public let identifier: String
    public let kind: NodeKind = .source
    /// Generated on the CPU once and cached; nothing to wait for.
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [Parameter(code: .opacity, range: 0...1, defaultValue: 1)]
    }

    /// Which pattern is generated. Changing it rebuilds the texture.
    public var pattern: Kind {
        didSet { if pattern != oldValue { texture = nil } }
    }

    private let context: MetalContext?
    private var texture: MTLTexture?
    private var textureSize: (width: Int, height: Int) = (0, 0)

    public init(identifier: String, pattern: Kind = .colorBars75, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.pattern = pattern
        self.context = context
    }

    /// The pattern as an `ImageBuffer`, for headless checks and for the output router.
    public func makeImage(width: Int = StandardDefinition.width, height: Int = StandardDefinition.height) -> ImageBuffer {
        switch pattern {
        case .colorBars75:
            TestPattern.colorBars(width: width, height: height)
        case .whiteField:
            TestPattern.solid(width: width, height: height, r: 235, g: 235, b: 235)
        case .blackField:
            TestPattern.solid(width: width, height: height, r: 19, g: 19, b: 19)
        case .crosshatch:
            TestPattern.crosshatch(width: width, height: height)
        case .pluge:
            TestPattern.pluge(width: width, height: height)
        case .grayscaleRamp:
            TestPattern.grayscaleRamp(width: width, height: height)
        }
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return nil }
        // The pattern is static, so it is built once and kept until the size or the
        // pattern changes — no per-frame allocation in the render loop (SPEC 1).
        if texture == nil || textureSize != (renderContext.width, renderContext.height) {
            let image = makeImage(width: renderContext.width, height: renderContext.height)
            texture = metal.makeTexture(from: image, label: "\(identifier)-\(pattern.rawValue)")
            textureSize = (renderContext.width, renderContext.height)
        }
        return texture
    }
}
