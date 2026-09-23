//
//  MissingModuleNode.swift — a chain card whose module cannot be made.
//
//  Purpose : A template or a chain can name a module that is not here any more — an
//            ISF file deleted or renamed, a module from a newer build. The card must
//            stay (with its values and mappings) and say so, and the picture must
//            pass through untouched: a missing effect is never a hole in the chain.
//  Inputs  : one texture.
//  Outputs : the same texture.
//  Connects: Engine.rebuildChain (stands one in), the FX card (shows `reason`).
//  Extend  : nothing to extend; the fix is putting the module back.
//

import Foundation
import Metal

/// Passes its input through and remembers why it is standing in.
public final class MissingModuleNode: Node, ParameterApplying {

    public let identifier: String
    public let kind: NodeKind = .effect
    /// Why the real module is not here, for the card.
    public let reason: String

    public var parameters: [Parameter] {
        [Parameter(code: .wetDry, range: 0...1, defaultValue: 0)]
    }

    public init(identifier: String, reason: String) {
        self.identifier = identifier
        self.reason = reason
    }

    public func render(inputs: [MTLTexture], context: RenderContext) -> MTLTexture? {
        inputs.first
    }

    public func applyParameters(from registry: ParamRegistry) {}
}
