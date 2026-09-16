//
//  Node.swift — the one extension point (SPEC 2, SPEC 1.5).
//
//  Purpose : Every source, effect and output in Videoboy is a `Node`. Adding a module
//            means conforming to this protocol and declaring its parameters. There is
//            deliberately no second plugin mechanism.
//  Inputs  : a `RenderContext` (frame timing, the Metal device, the graph's format).
//  Outputs : a texture, produced into the context's target.
//  Connects: RenderGraph (evaluation order), ParamRegistry (mappable parameters),
//            templates (serialisation of the graph shape).
//  Extend  : see docs/ADD-A-MODULE.md. Copy Modules/_Template and fill in four members.
//

import Foundation
import Metal

/// What a node is for. Drives where it may sit in the graph and which panel lists it.
public enum NodeKind: String, Codable, Sendable {
    /// Produces a picture from nothing: a file, a capture device, a generator.
    case source
    /// Transforms one picture into another.
    case effect
    /// Combines two pictures: a crossfade, a layer composite.
    case mix
    /// Consumes a picture: a display, a recorder, a scope.
    case output
}

/// Per-frame state handed to every node as the graph is evaluated.
public struct RenderContext {
    /// The frame being produced, counted from transport start.
    public let frameIndex: Int
    /// Host time this frame is intended to be presented at, in seconds.
    public let presentationTime: Double
    /// Musical position, when the transport is running. Nil when it is stopped.
    public let musicalPosition: MusicalPosition?
    /// Project geometry. Every texture in the graph is this size.
    public let width: Int
    public let height: Int

    public init(
        frameIndex: Int,
        presentationTime: Double,
        musicalPosition: MusicalPosition?,
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height
    ) {
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.musicalPosition = musicalPosition
        self.width = width
        self.height = height
    }
}

/// A node in the render graph.
///
/// Conforming types implement four things. Everything else — placement, mapping,
/// serialisation, scheduling — is handled by the graph around them.
public protocol Node: AnyObject {

    /// Stable identifier for this node instance, used as the mapping slot name and
    /// as the template key. Must not change across a save/load cycle.
    var identifier: String { get }

    /// What kind of node this is.
    var kind: NodeKind { get }

    /// The parameters this node exposes, by stable code (SPEC 13).
    ///
    /// Returning the same codes after a module swap is what preserves mappings, so
    /// use the shared codes from `ParamCode` wherever the parameter is a common one.
    var parameters: [Parameter] { get }

    /// Processing latency in frames, declared so the scheduler can compensate.
    ///
    /// A node that must act *on* a beat is scheduled for `T − latency` so the visible
    /// result lands on `T` (SPEC 4b). Return 0 if the node is immediate.
    var latencyInFrames: Int { get }

    /// Produces this node's output for one frame.
    ///
    /// - Parameters:
    ///   - inputs: upstream textures, in the order the graph's edges declare them.
    ///   - context: frame timing and geometry.
    /// - Returns: the output texture, or nil when the node has nothing to show —
    ///   which must render as a labelled empty state, never a crash (SPEC 1.5).
    func render(inputs: [MTLTexture], context: RenderContext) -> MTLTexture?
}

public extension Node {
    /// Most nodes are immediate.
    var latencyInFrames: Int { 0 }
}
