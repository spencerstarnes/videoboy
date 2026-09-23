//
//  EffectChainTests.swift — the chain as data, and the catalogue it draws from.
//
//  The rules a performer relies on without thinking about them: the top card is
//  applied last; adding never moves the cards already there; removing one takes out
//  exactly that one; slot names are the ones every old template and mapping uses; a
//  dropped-in ISF file becomes a module with a fader per input; a broken one is
//  listed as broken, not hidden.
//

import XCTest
@testable import VideoboyCore

final class EffectChainTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - The chain

    func testTheStandardChainKeepsTheOldSlotsAndSignalOrder() {
        let chain = EffectChain.standard
        XCTAssertEqual(chain.entries.map(\.instanceID),
                       ["mosh", "transform", "colour", "composite", "echo", "feedback", "freeze"],
                       "today's signal order, MX-1 replaced by freeze")
        XCTAssertEqual(EffectChain.slot(instanceID: "colour", lane: "A"), "fx.a.colour")
        XCTAssertEqual(EffectChain.slot(instanceID: "echo", lane: ChainBus.one.lane), "fx.one.echo",
                       "the same slot names the hard-wired chain used, so old mappings still land")
        XCTAssertEqual(EffectChain.slots(instanceID: "echo", bus: .two), ["fx.c.echo", "fx.d.echo", "fx.two.echo"])
    }

    func testThePanelShowsTheChainUpsideDown() {
        // SPEC 14.2: like Photoshop layers, the top card is the last thing applied.
        XCTAssertEqual(EffectChain.standard.displayOrder.first?.instanceID, "freeze")
        XCTAssertEqual(EffectChain.standard.displayOrder.last?.instanceID, "mosh")
    }

    func testAddingPutsTheNewCardAtTheBottomSoNothingMoves() {
        var chain = EffectChain.standard
        let before = chain.displayOrder.map(\.instanceID)
        let added = chain.add(moduleID: ModuleCatalog.ID.isf("Bad TV"))
        XCTAssertEqual(added.instanceID, "isf-bad-tv")
        XCTAssertEqual(chain.displayOrder.map(\.instanceID), before + ["isf-bad-tv"],
                       "every existing card keeps its place on screen")
        XCTAssertEqual(chain.entries.first?.instanceID, "isf-bad-tv", "…so it is applied first")
        XCTAssertEqual(added.target, ChainEntry.both)

        let second = chain.add(moduleID: ModuleCatalog.ID.isf("Bad TV"))
        XCTAssertEqual(second.instanceID, "isf-bad-tv-2", "two instances never share a slot")
    }

    func testReorderFollowsThePanelAndNeverDropsACard() {
        var chain = EffectChain.standard
        chain.reorder(displayOrder: ["mosh", "freeze", "feedback", "echo", "composite", "colour", "transform"])
        XCTAssertEqual(chain.entries.map(\.instanceID),
                       ["transform", "colour", "composite", "echo", "feedback", "freeze", "mosh"])

        // A stale list (one id unknown, one missing) keeps every real card.
        chain.reorder(displayOrder: ["ghost", "colour", "transform"])
        XCTAssertEqual(Set(chain.entries.map(\.instanceID)), Set(EffectChain.standard.entries.map(\.instanceID)))
        XCTAssertEqual(chain.displayOrder.prefix(2).map(\.instanceID), ["colour", "transform"],
                       "the listed cards take the top, the rest follow in their old order")
    }

    func testRemoveAndReAddReusesTheBuiltInsSlot() {
        var chain = EffectChain.standard
        XCTAssertTrue(chain.remove("colour"))
        XCTAssertFalse(chain.remove("colour"))
        let back = chain.add(moduleID: ModuleCatalog.ID.colour, preferredID: "colour")
        XCTAssertEqual(back.instanceID, "colour", "a built-in comes back on its old slot, with its mappings")
    }

    func testTargetsPickTheCopyTheCardEdits() {
        var chain = EffectChain.standard
        let echo = chain.entry("echo")!
        XCTAssertEqual(EffectChain.targetedSlot(of: echo, bus: .one), "fx.a.echo")
        chain.setTarget(1, of: "echo")
        XCTAssertEqual(EffectChain.targetedSlot(of: chain.entry("echo")!, bus: .two), "fx.d.echo")
        chain.setTarget(9, of: "echo")
        XCTAssertEqual(EffectChain.targetedSlot(of: chain.entry("echo")!, bus: .one), "fx.one.echo", "clamped to BOTH")
    }

    // MARK: - Templates

    func testATemplateCarriesTheChainAndAnOldOneGetsTheStandardChain() throws {
        var chain = EffectChain.standard
        chain.add(moduleID: ModuleCatalog.ID.isf("Kaleido"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TemplateDocument(chains: ["one": chain]).write(to: url)
        let back = try TemplateDocument.read(from: url)
        XCTAssertEqual(back.chain(for: .one), chain)
        XCTAssertEqual(back.chain(for: .two), .standard, "a bus the template does not mention gets the standard chain")
        XCTAssertEqual(back.version, 2)

        // A version-1 file: no chains key at all.
        let old = #"{ "version": 1, "name": "old", "nodes": [ { "identifier": "fx.one.colour", "moduleType": "ColourControlNode", "parameters": { "53A": 0.4 } } ] }"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        let migrated = try TemplateDocument.read(from: url)
        XCTAssertEqual(migrated.chain(for: .one), .standard)
        XCTAssertEqual(migrated.nodes.first?.identifier, "fx.one.colour",
                       "its values still address the standard chain's slots")
    }

    // MARK: - The catalogue

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheCatalogueOffersNativesBuiltInsAndDroppedInFiles() throws {
        let user = try tempFolder()
        try """
        /*{ "CATEGORIES": ["Glitch"], "INPUTS": [
            { "NAME": "inputImage", "TYPE": "image" },
            { "NAME": "noise", "TYPE": "float", "LABEL": "noise" },
            { "NAME": "tint", "TYPE": "color" } ] }*/
        void main() { gl_FragColor = IMG_THIS_PIXEL(inputImage) * tint + noise; }
        """.write(to: user.appendingPathComponent("Bad TV.fs"), atomically: true, encoding: .utf8)
        try """
        /*{ "INPUTS": [] }*/
        void main() { gl_FragColor = vec4(1.0); }
        """.write(to: user.appendingPathComponent("Plain Generator.fs"), atomically: true, encoding: .utf8)
        try "not a shader".write(to: user.appendingPathComponent("Broken.fs"), atomically: true, encoding: .utf8)

        let catalog = ModuleCatalog(folders: [(ISFLibrary.builtinFolder, .builtin), (user, .user)])
        let names = catalog.modules.map(\.name)
        XCTAssertEqual(Array(names.prefix(4)), ["Composite · NTSC", "Datamosh · H.264", "Feedback", "Freeze"],
                       "natives first, by name")
        XCTAssertTrue(names.contains("Colour") && names.contains("Transform") && names.contains("Echo / Trails"))

        let badTV = try XCTUnwrap(catalog.module(ModuleCatalog.ID.isf("Bad TV")))
        XCTAssertEqual(badTV.origin, .imported)
        XCTAssertEqual(badTV.group, "Glitch", "the Add menu groups by the file's own category")
        XCTAssertEqual(badTV.controls.map(\.code.rawValue), ["x:noise", "x:tint.r", "x:tint.g", "x:tint.b", "x:tint.a"])
        XCTAssertFalse(names.contains("Plain Generator"), "a generator is a source, not a chain effect")
        XCTAssertEqual(catalog.unavailable.map(\.name), ["Broken"], "a broken file is listed as broken, with its reason")
        XCTAssertNotNil(catalog.unavailable.first?.problem)

        let colour = try XCTUnwrap(catalog.module(ModuleCatalog.ID.colour))
        XCTAssertEqual(colour.controls.first?.code, .brightness, "the built-in port keeps the native codes")
        XCTAssertEqual(colour.origin.badge, "built-in")
    }

    func testFactoriesMakeTheRightNodes() throws {
        let catalog = ModuleCatalog(folders: [(ISFLibrary.builtinFolder, .builtin)])
        let freeze = catalog.module(ModuleCatalog.ID.freeze)?.makeNode(identifier: "fx.a.freeze", context: nil)
        XCTAssertTrue(freeze is FreezeNode)
        XCTAssertEqual(freeze?.identifier, "fx.a.freeze")
        let colour = catalog.module(ModuleCatalog.ID.colour)?.makeNode(identifier: "fx.one.colour", context: nil)
        let isf = try XCTUnwrap(colour as? ISFNode)
        XCTAssertTrue(isf.parameters.contains { $0.code == .contrast },
                      "an ISF module's controls are known as soon as the node exists")
    }
}
