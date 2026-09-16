//
//  ParamAndTemplateTests.swift — param-code resolution and template round-trips.
//
//  Purpose : The other two fragile bones from SPEC 1.5. Param codes exist so a
//            mapping survives a module swap; templates exist so a setup survives a
//            save, an app update, and being edited by hand in a text editor. Both
//            fail silently if they fail at all, so both are pinned down here.
//  Inputs  : registries and documents built in-test; no files beyond a temp path.
//  Outputs : assertions.
//  Connects: ParamCode, ParamRegistry, TemplateDocument.
//  Extend  : adding a param code means adding it to `testCodesAreUniqueAndStable`.
//

import XCTest
@testable import VideoboyCore

final class ParamAndTemplateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Param codes

    func testCodesAreUniqueAndStable() {
        let codes = ParamCode.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(codes).count, codes.count,
            "two parameters share a code — an old template would bind to the wrong one"
        )
        // Spot-check the reserved common codes from SPEC 13. These values are
        // permanent; changing one silently breaks every saved template.
        XCTAssertEqual(ParamCode.opacity.rawValue, "01A")
        XCTAssertEqual(ParamCode.scale.rawValue, "11A")
        XCTAssertEqual(ParamCode.corruptAmount.rawValue, "31B")
        XCTAssertEqual(ParamCode.corruptRate.rawValue, "33B")
    }

    func testEveryCodeHasADisplayName() {
        for code in ParamCode.allCases {
            XCTAssertFalse(code.displayName.isEmpty, "\(code.rawValue) has no display name")
        }
    }

    func testParameterDenormalisesIntoItsOwnRange() {
        let parameter = Parameter(code: .playbackSpeed, range: -2...2, defaultValue: 1)
        XCTAssertEqual(parameter.denormalise(0), -2, accuracy: 1e-9)
        XCTAssertEqual(parameter.denormalise(0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(parameter.denormalise(1), 2, accuracy: 1e-9)
        // Out-of-range control values clamp instead of running off the end.
        XCTAssertEqual(parameter.denormalise(2), 2, accuracy: 1e-9)
    }

    // MARK: - The property that matters: mappings survive a module swap

    func testSwappingAModulePreservesMappingsWhoseCodesPersist() throws {
        let registry = ParamRegistry()
        let slot = "subMixOne.fx0"

        // A module exposing wet/dry, corrupt amount and dot crawl.
        registry.register(slot: slot, parameters: [
            Parameter(code: .wetDry, defaultValue: 1.0),
            Parameter(code: .corruptAmount, defaultValue: 0.0),
            Parameter(code: .compositeCrawl, defaultValue: 0.5)
        ])

        let knob = ControlSource.midiControlChange(channel: 0, controller: 21)
        let crawlKnob = ControlSource.midiControlChange(channel: 0, controller: 22)
        registry.bind(ControlBinding(source: knob, slot: slot, code: .corruptAmount))
        registry.bind(ControlBinding(source: crawlKnob, slot: slot, code: .compositeCrawl))

        registry.deliver(normalisedValue: 0.75, from: knob)
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0.75, accuracy: 1e-9)

        // Swap in a different module: it keeps wet/dry and corrupt amount, but has no
        // dot crawl and adds a feedback gain.
        registry.register(slot: slot, parameters: [
            Parameter(code: .wetDry, defaultValue: 1.0),
            Parameter(code: .corruptAmount, defaultValue: 0.0),
            Parameter(code: .feedbackGain, defaultValue: 0.2)
        ])

        // The surviving mapping still works...
        XCTAssertEqual(
            try XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0.75, accuracy: 1e-9,
            "a value must carry across a swap when its code survives"
        )
        registry.deliver(normalisedValue: 0.25, from: knob)
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: slot, code: .corruptAmount)), 0.25, accuracy: 1e-9)

        // ...and the mapping whose code vanished is kept, not deleted.
        XCTAssertEqual(registry.bindings.count, 2, "a dangling mapping must be preserved")
        XCTAssertEqual(registry.resolvableBindings.count, 1)
        XCTAssertEqual(registry.danglingBindings.first?.code, .compositeCrawl)

        // Delivering to the dangling mapping is a no-op, not a crash.
        XCTAssertTrue(registry.deliver(normalisedValue: 1.0, from: crawlKnob).isEmpty)

        // Swapping the original module back restores the mapping.
        registry.register(slot: slot, parameters: [
            Parameter(code: .wetDry, defaultValue: 1.0),
            Parameter(code: .corruptAmount, defaultValue: 0.0),
            Parameter(code: .compositeCrawl, defaultValue: 0.5)
        ])
        XCTAssertEqual(registry.resolvableBindings.count, 2, "swapping back must revive the mapping")
    }

    func testRelearningAKnobMovesItRatherThanStacking() {
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [
            Parameter(code: .opacity), Parameter(code: .scale)
        ])
        let knob = ControlSource.midiControlChange(channel: 1, controller: 7)
        registry.bind(ControlBinding(source: knob, slot: "a", code: .opacity))
        registry.bind(ControlBinding(source: knob, slot: "a", code: .scale))

        XCTAssertEqual(registry.bindings.count, 1, "one control drives one parameter")
        XCTAssertEqual(registry.bindings.first?.code, .scale)
    }

    func testDeliveringToAnUnmappedSourceDoesNothing() {
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [Parameter(code: .opacity)])
        let applied = registry.deliver(
            normalisedValue: 1.0, from: .midiControlChange(channel: 0, controller: 99))
        XCTAssertTrue(applied.isEmpty)
    }

    func testSettingAnUnknownCodeIsRefusedNotCrashed() {
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [Parameter(code: .opacity)])
        XCTAssertFalse(registry.setValue(0.5, slot: "a", code: .feedbackGain))
        XCTAssertFalse(registry.setValue(0.5, slot: "nonexistent", code: .opacity))
    }

    // MARK: - Templates

    func testTemplateRoundTripsExactly() throws {
        let original = TemplateDocument(
            name: "latenight_vhs",
            nodes: [
                TemplateNode(
                    identifier: GraphTopology.sourceA, moduleType: "DVSource",
                    parameters: [
                        ParamCode.corruptAmount.rawValue: 0.42,
                        ParamCode.playbackSpeed.rawValue: 1.0
                    ],
                    mediaPath: "samples/motion.dv"
                ),
                TemplateNode(identifier: GraphTopology.subMixOne, moduleType: "CrossfadeNode",
                             parameters: [ParamCode.crossfadeAB.rawValue: 0.25])
            ],
            edges: [
                GraphEdge(from: GraphTopology.sourceA, to: GraphTopology.subMixOne, inputIndex: 0),
                GraphEdge(from: GraphTopology.sourceB, to: GraphTopology.subMixOne, inputIndex: 1)
            ],
            mappings: [
                TemplateMapping(
                    source: .midiControlChange(channel: 0, controller: 21),
                    slot: GraphTopology.sourceA, code: ParamCode.corruptAmount.rawValue
                ),
                TemplateMapping(source: .osc(address: "/videoboy/fade"),
                                slot: GraphTopology.subMixOne, code: ParamCode.crossfadeAB.rawValue)
            ],
            clock: TemplateClock(beatsPerMinute: 124, beatsPerBar: 4, subdivision: "1/8"),
            layout: TemplateLayout(collapsedPanels: ["Sub Mix 2 FX"])
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-template-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.write(to: url)
        let reloaded = try TemplateDocument.read(from: url)
        XCTAssertEqual(reloaded, original, "a template must survive a save/load cycle unchanged")
    }

    func testTemplateIsHumanReadableAndHandEditable() throws {
        let document = TemplateDocument(
            name: "hand-edit-me",
            clock: TemplateClock(beatsPerMinute: 133)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-readable-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.write(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        // Pretty-printed and readable, as SPEC 16 requires.
        XCTAssertTrue(text.contains("\n"), "a template must not be one long line")
        XCTAssertTrue(text.contains("hand-edit-me"))
        XCTAssertTrue(text.contains("133"))

        // Now edit it the way a person would, and check it still loads.
        let edited = text.replacingOccurrences(of: "133", with: "90")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let reloaded = try TemplateDocument.read(from: url)
        XCTAssertEqual(reloaded.clock.beatsPerMinute, 90, accuracy: 1e-9)
    }

    func testMissingSectionsFallBackToDefaults() throws {
        // A minimal, hand-written template with almost everything left out.
        let minimal = #"{ "name": "sparse" }"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-sparse-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: url) }
        try minimal.write(to: url, atomically: true, encoding: .utf8)

        let document = try TemplateDocument.read(from: url)
        XCTAssertEqual(document.name, "sparse")
        XCTAssertEqual(document.version, TemplateDocument.currentVersion)
        XCTAssertTrue(document.nodes.isEmpty)
        XCTAssertEqual(document.clock.beatsPerMinute, 120, accuracy: 1e-9)
    }

    func testUnknownParamCodesArePreservedNotFatal() throws {
        // A template written by a future build, holding a code this one has never
        // heard of. SPEC 16: unknown keys are preserved and ignored, never fatal.
        let future = """
        {
          "name": "from-the-future",
          "version": 99,
          "nodes": [
            { "identifier": "source.a", "moduleType": "DVSource",
              "parameters": { "31B": 0.5, "99Z": 0.25 } }
          ],
          "mappings": [
            { "source": { "midiControlChange": { "channel": 0, "controller": 3 } },
              "slot": "source.a", "code": "99Z" }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-future-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: url) }
        try future.write(to: url, atomically: true, encoding: .utf8)

        let document = try TemplateDocument.read(from: url)
        XCTAssertEqual(document.version, 99)
        XCTAssertEqual(document.nodes.first?.parameters["99Z"], 0.25,
                       "an unknown code must be kept in the document")

        let registry = ParamRegistry()
        registry.register(slot: "source.a", parameters: [Parameter(code: .corruptAmount)])
        let unknownCount = document.apply(to: registry)

        // The known code applied; the unknown one was reported and skipped.
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: "source.a", code: .corruptAmount)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(unknownCount, 1)

        // And writing it back out must not lose the unknown key.
        let rewritten = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-future2-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: rewritten) }
        try document.write(to: rewritten)
        let reloaded = try TemplateDocument.read(from: rewritten)
        XCTAssertEqual(reloaded.nodes.first?.parameters["99Z"], 0.25)
    }

    func testCorruptTemplateFileIsReportedNotCrashed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-bad-\(UUID().uuidString).vbt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "this is not json at all".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TemplateDocument.read(from: url)) { error in
            guard case TemplateDocument.TemplateError.cannotParse = error else {
                return XCTFail("expected a parse error, got \(error)")
            }
        }
    }

    // MARK: - Graph

    func testEvaluationOrderPutsSourcesBeforeTheMixTheyFeed() {
        let graph = RenderGraph()
        graph.add(StubNode(identifier: GraphTopology.sourceA, kind: .source))
        graph.add(StubNode(identifier: GraphTopology.sourceB, kind: .source))
        graph.add(StubNode(identifier: GraphTopology.subMixOne, kind: .mix))
        graph.connect(from: GraphTopology.sourceA, to: GraphTopology.subMixOne, inputIndex: 0)
        graph.connect(from: GraphTopology.sourceB, to: GraphTopology.subMixOne, inputIndex: 1)

        let order = graph.evaluationOrder(from: GraphTopology.subMixOne)
        XCTAssertEqual(order.last, GraphTopology.subMixOne)
        XCTAssertTrue(order.contains(GraphTopology.sourceA))
        XCTAssertTrue(order.contains(GraphTopology.sourceB))
        XCTAssertLessThan(order.firstIndex(of: GraphTopology.sourceA)!,
                          order.firstIndex(of: GraphTopology.subMixOne)!)
    }

    func testFixedRoutingIsNotRemappable() {
        // SPEC 2 is a hard rule: A and B always feed ONE, C and D always feed TWO.
        XCTAssertEqual(GraphTopology.subMix(forChannel: GraphTopology.sourceA), GraphTopology.subMixOne)
        XCTAssertEqual(GraphTopology.subMix(forChannel: GraphTopology.sourceB), GraphTopology.subMixOne)
        XCTAssertEqual(GraphTopology.subMix(forChannel: GraphTopology.sourceC), GraphTopology.subMixTwo)
        XCTAssertEqual(GraphTopology.subMix(forChannel: GraphTopology.sourceD), GraphTopology.subMixTwo)
    }

    func testCycleIsBrokenRatherThanHanging() {
        let graph = RenderGraph()
        graph.add(StubNode(identifier: "a", kind: .effect))
        graph.add(StubNode(identifier: "b", kind: .effect))
        graph.connect(from: "a", to: "b")
        graph.connect(from: "b", to: "a")
        // The assertion is simply that this returns at all.
        let order = graph.evaluationOrder(from: "a")
        XCTAssertFalse(order.isEmpty)
    }

    func testMaximumLatencyIsTheAlignmentTarget() {
        let graph = RenderGraph()
        graph.add(StubNode(identifier: "fast", kind: .effect, latency: 0))
        graph.add(StubNode(identifier: "slow", kind: .effect, latency: 5))
        XCTAssertEqual(graph.maximumLatencyInFrames, 5)
    }
}

/// A do-nothing node, for graph-shape tests that do not need pixels.
private final class StubNode: Node {
    let identifier: String
    let kind: NodeKind
    let parameters: [Parameter]
    let latencyInFrames: Int

    init(identifier: String, kind: NodeKind, latency: Int = 0, parameters: [Parameter] = []) {
        self.identifier = identifier
        self.kind = kind
        self.latencyInFrames = latency
        self.parameters = parameters
    }

    func render(inputs: [MTLTexture], context: RenderContext) -> MTLTexture? { nil }
}
