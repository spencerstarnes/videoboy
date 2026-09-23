//
//  RenderGraph.swift — the graph as data (SPEC 2).
//
//  Purpose : Holds nodes and typed edges as a plain data structure, so a template
//            (SPEC 16) is just a serialisation of it. Evaluation order is derived
//            here, not hardcoded at call sites.
//  Inputs  : nodes and edges added by the app.
//  Outputs : an evaluation order, and the node count shown in the status bar.
//  Connects: Node (the members), ParamRegistry (each node registers its parameters),
//            TemplateDocument (which reads and writes this shape).
//  Extend  : the fixed A/B->ONE, C/D->TWO routing is enforced in `GraphTopology`, not
//            here; this type stays a general graph so future phases can grow it.
//

import Foundation

/// A connection between two nodes. `inputIndex` is the slot on the destination, which
/// is what makes a two-input node (a crossfade) unambiguous.
public struct GraphEdge: Equatable, Codable, Sendable {
    public let from: String
    public let to: String
    public let inputIndex: Int

    public init(from: String, to: String, inputIndex: Int = 0) {
        self.from = from
        self.to = to
        self.inputIndex = inputIndex
    }
}

/// Nodes plus edges, with a derived evaluation order.
public final class RenderGraph {

    /// Nodes by identifier.
    private(set) public var nodes: [String: Node] = [:]
    /// All edges.
    private(set) public var edges: [GraphEdge] = []

    public init() {}

    /// Number of nodes, shown in the status bar.
    public var nodeCount: Int { nodes.count }

    /// Adds a node. Replacing an existing identifier is how a module swap happens,
    /// and is deliberately allowed.
    public func add(_ node: Node) {
        if nodes[node.identifier] != nil {
            Log.info(.graph, "replacing node '\(node.identifier)' (module swap)")
        }
        nodes[node.identifier] = node
    }

    /// Takes a node out, with every edge into or out of it. What it fed is left with
    /// an empty input until something is connected there (the chain rewire does that
    /// in the same step, between ticks).
    public func remove(_ identifier: String) {
        guard nodes.removeValue(forKey: identifier) != nil else { return }
        edges.removeAll { $0.from == identifier || $0.to == identifier }
        Log.info(.graph, "removed node '\(identifier)'")
    }

    /// Connects two nodes. Both ends must already exist.
    @discardableResult
    public func connect(from: String, to: String, inputIndex: Int = 0) -> Bool {
        guard nodes[from] != nil else {
            Log.error(.graph, "cannot connect from unknown node '\(from)'")
            return false
        }
        guard nodes[to] != nil else {
            Log.error(.graph, "cannot connect to unknown node '\(to)'")
            return false
        }
        // One edge per destination slot: connecting again replaces it.
        edges.removeAll { $0.to == to && $0.inputIndex == inputIndex }
        edges.append(GraphEdge(from: from, to: to, inputIndex: inputIndex))
        return true
    }

    /// Upstream node identifiers feeding a node, ordered by input slot.
    public func inputs(of identifier: String) -> [String] {
        edges
            .filter { $0.to == identifier }
            .sorted { $0.inputIndex < $1.inputIndex }
            .map(\.from)
    }

    /// Evaluation order: every node appears after everything feeding it.
    ///
    /// A depth-first walk with a visiting set. A cycle is logged and broken rather
    /// than hanging the render thread — a malformed template must not freeze a show.
    public func evaluationOrder(from root: String) -> [String] {
        var order: [String] = []
        var visited: Set<String> = []
        var visiting: Set<String> = []

        func visit(_ identifier: String) {
            if visited.contains(identifier) { return }
            if visiting.contains(identifier) {
                Log.error(.graph, "cycle detected at node '\(identifier)'; breaking it")
                return
            }
            visiting.insert(identifier)
            for upstream in inputs(of: identifier) { visit(upstream) }
            visiting.remove(identifier)
            visited.insert(identifier)
            order.append(identifier)
        }

        guard nodes[root] != nil else {
            Log.error(.graph, "evaluation root '\(root)' is not in the graph")
            return []
        }
        visit(root)
        return order
    }

    /// The largest declared latency in the graph. Everything aligns to this so all
    /// scheduled events land on the beat together (SPEC 4b).
    public var maximumLatencyInFrames: Int {
        nodes.values.map(\.latencyInFrames).max() ?? 0
    }

    /// Registers every node's parameters into a registry, using the node identifier
    /// as the mapping slot. Call after building or swapping nodes.
    public func registerParameters(into registry: ParamRegistry) {
        for (identifier, node) in nodes {
            registry.register(slot: identifier, parameters: node.parameters)
        }
    }
}

/// The fixed routing from SPEC 2, named so the rule is stated once in code.
///
/// A+B always feed ONE and C+D always feed TWO. This is a hard rule from the brief
/// and these identifiers are what enforce it.
public enum GraphTopology {
    public static let sourceA = "source.a"
    public static let sourceB = "source.b"
    public static let sourceC = "source.c"
    public static let sourceD = "source.d"
    public static let subMixOne = "mix.one"
    public static let subMixTwo = "mix.two"
    public static let primary = "mix.primary"

    /// Which sub-mix a channel feeds. Never remapped.
    public static func subMix(forChannel channel: String) -> String {
        switch channel {
        case sourceA, sourceB: subMixOne
        case sourceC, sourceD: subMixTwo
        default: primary
        }
    }
}
