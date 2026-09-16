//
//  PanelSet.swift — constructs all sixteen panels, once.
//
//  Purpose : One place where every panel in SPEC 14.2 is built with its title, bus
//            identity, subtitle and body. PanelGridView places them; the app wires
//            them. Keeping construction here means the full inventory is readable in
//            one screen, which is how "every panel is present" stays verifiable.
//  Inputs  : none.
//  Outputs : the panels, as named properties.
//  Connects: PanelGridView (placement), the panel body types, the app (wiring).
//  Extend  : a new panel means the mockup changed. Change SPEC 14 and the mockup first.
//

import AppKit
import VideoboyCore

/// Every panel in the window, built and named.
final class PanelSet {

    // Sources (outer columns, rows 0-1)
    let sourceA: PanelView
    let sourceB: PanelView
    let sourceC: PanelView
    let sourceD: PanelView

    // Previews (inner columns, rows 0-1)
    let subMixOne: PanelView
    let program: PanelView
    let subMixTwo: PanelView

    // Faders (row 2)
    let faderAB: PanelView
    let faderOneTwo: PanelView
    let faderCD: PanelView

    // Effect chains (outer columns, rows 2-4)
    let effectsOne: PanelView
    let effectsTwo: PanelView

    // Libraries and browser (row 3)
    let libraryOne: PanelView
    let assetBrowser: PanelView
    let libraryTwo: PanelView

    // Settings bar (row 4, spanning the inner columns)
    let settingsBar: PanelView

    // The body views, kept so the app can wire them without walking the view tree.
    let sourceBodies: [String: SourcePanelBody]
    let subMixOneBody: PreviewPanelBody
    let subMixTwoBody: PreviewPanelBody
    let programBody: PreviewPanelBody
    let faderABBody: FaderPanelBody
    let faderCDBody: FaderPanelBody
    let faderOneTwoBody: FaderPanelBody
    let settingsBarBody: SettingsBarPanelBody
    let effectsOneBody: EffectChainPanelBody
    let effectsTwoBody: EffectChainPanelBody

    init() {
        // MARK: Sources
        let bodyA = SourcePanelBody(channel: "A")
        let bodyB = SourcePanelBody(channel: "B")
        let bodyC = SourcePanelBody(channel: "C")
        let bodyD = SourcePanelBody(channel: "D")
        sourceBodies = ["A": bodyA, "B": bodyB, "C": bodyC, "D": bodyD]

        sourceA = PanelView(title: "Source: A", bus: .one, body: bodyA)
        sourceB = PanelView(title: "Source: B", bus: .one, body: bodyB)
        sourceC = PanelView(title: "Source: C", bus: .two, body: bodyC)
        sourceD = PanelView(title: "Source: D", bus: .two, body: bodyD)

        // MARK: Previews
        // Subtitles state the fixed routing, which never remaps (SPEC 2).
        subMixOneBody = PreviewPanelBody(caption: "100 IRE")
        subMixTwoBody = PreviewPanelBody(caption: "7.5 IRE")
        programBody = PreviewPanelBody(caption: "\(StandardDefinition.width)×\(StandardDefinition.height)")

        subMixOne = PanelView(title: "Sub Mix One", bus: .one, subtitle: "A ▸ B", body: subMixOneBody)
        subMixTwo = PanelView(title: "Sub Mix Two", bus: .two, subtitle: "C ▸ D", body: subMixTwoBody)
        program = PanelView(title: "Program Preview", subtitle: "ONE ▸ TWO", body: programBody)

        // MARK: Faders
        faderABBody = FaderPanelBody(
            leftLabel: "A", rightLabel: "B",
            leftColor: Theme.Color.busOne, rightColor: Theme.Color.textSecondary,
            includesSwap: false
        )
        faderCDBody = FaderPanelBody(
            leftLabel: "C", rightLabel: "D",
            leftColor: Theme.Color.busTwo, rightColor: Theme.Color.textSecondary,
            includesSwap: false
        )
        faderOneTwoBody = FaderPanelBody(
            leftLabel: "ONE", rightLabel: "TWO",
            leftColor: Theme.Color.busOne, rightColor: Theme.Color.busTwo,
            includesSwap: true
        )
        faderAB = PanelView(title: "A → B Fader", bus: .one, body: faderABBody)
        faderCD = PanelView(title: "C → D Fader", bus: .two, body: faderCDBody)
        faderOneTwo = PanelView(title: "ONE → TWO Fader", body: faderOneTwoBody)

        // MARK: Effect chains
        //
        // The DV DIF corruptor is the one effect that is real in this phase — it is
        // the wedge. Everything else is present and disabled so the chain's shape is
        // visible from the first run.
        effectsOneBody = EffectChainPanelBody(effects: [
            EffectCardModel(
                name: "DV · DIF corruptor",
                isEnabled: true,
                isImplemented: FeatureFlag.bitstreamCorruptor.isOn,
                parameters: [
                    EffectParameterModel(name: "amount", code: ParamCode.corruptAmount.rawValue,
                                         value: 0.0, activeBadges: [], enabled: true),
                    EffectParameterModel(name: "mode", code: ParamCode.corruptMode.rawValue,
                                         value: 0.0, activeBadges: [], enabled: true),
                    EffectParameterModel(name: "rate", code: ParamCode.corruptRate.rawValue,
                                         value: 0.25, activeBadges: ["C"], enabled: true)
                ]
            ),
            EffectCardModel(name: "Composite · NTSC", isEnabled: false, isImplemented: false, parameters: [
                EffectParameterModel(name: "crawl", code: ParamCode.compositeCrawl.rawValue,
                                     value: 0.6, activeBadges: [], enabled: false)
            ]),
            EffectCardModel(name: "Color Ctrl", isEnabled: false, isImplemented: false, parameters: [
                EffectParameterModel(name: "contrast", code: ParamCode.contrast.rawValue,
                                     value: 0.62, activeBadges: [], enabled: false)
            ]),
            EffectCardModel(name: "Layer Mask", isEnabled: false, isImplemented: false, parameters: [])
        ])

        effectsTwoBody = EffectChainPanelBody(effects: [
            EffectCardModel(name: "Echo / Trails", isEnabled: false, isImplemented: false, parameters: [
                EffectParameterModel(name: "decay", code: ParamCode.echoDecay.rawValue,
                                     value: 0.55, activeBadges: [], enabled: false)
            ]),
            EffectCardModel(name: "Feedback", isEnabled: false, isImplemented: false, parameters: [
                EffectParameterModel(name: "delay", code: ParamCode.feedbackDelayFrames.rawValue,
                                     value: 0.2, activeBadges: [], enabled: false)
            ]),
            EffectCardModel(name: "Color Invert", isEnabled: false, isImplemented: false, parameters: []),
            EffectCardModel(name: "Layer Mask", isEnabled: false, isImplemented: false, parameters: [])
        ])

        effectsOne = PanelView(title: "Sub Mix 1 FX", bus: .one, body: effectsOneBody)
        effectsTwo = PanelView(title: "Sub Mix 2 FX", bus: .two, body: effectsTwoBody)

        // MARK: Libraries
        // The sub-mix libraries start from what is actually in samples/; the central
        // browser shows the full inventory of source kinds, with unbuilt ones greyed.
        let sampleItems = PanelSet.sampleLibraryItems()
        libraryOne = PanelView(
            title: "Sub Mix 1 Library", subtitle: "A/B",
            body: LibraryPanelBody(items: sampleItems, columns: 3, showsTabs: false)
        )
        libraryTwo = PanelView(
            title: "Sub Mix 2 Library", subtitle: "C/D",
            body: LibraryPanelBody(items: sampleItems, columns: 3, showsTabs: false)
        )
        assetBrowser = PanelView(
            title: "Asset Browser",
            body: LibraryPanelBody(items: sampleItems + PanelSet.futureSourceKinds(), columns: 6, showsTabs: true)
        )

        // MARK: Settings bar
        settingsBarBody = SettingsBarPanelBody(negotiatedMode: "not yet negotiated")
        settingsBar = PanelView(title: "Output", body: settingsBarBody)
        settingsBar.setCollapsed(false)
    }

    /// Library entries for whatever is currently in samples/.
    private static func sampleLibraryItems() -> [LibraryItem] {
        let manifestURL = RepoPaths.samples.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else {
            Log.warn(.app, "no samples/manifest.json; libraries start empty")
            return []
        }
        return samples.compactMap { entry in
            guard let file = entry["file"] as? String else { return nil }
            let badge = (entry["kind"] as? String) == "dv"
                ? "DV"
                : (file as NSString).pathExtension.uppercased()
            return LibraryItem(name: file, badge: badge, isAvailable: true)
        }
    }

    /// Source kinds the browser advertises but cannot load yet. Shown greyed so the
    /// intended scope is visible without pretending they work.
    private static func futureSourceKinds() -> [LibraryItem] {
        [
            LibraryItem(name: "plasma", badge: "GEN", isAvailable: false),
            LibraryItem(name: "logo.svg", badge: "SVG", isAvailable: false),
            LibraryItem(name: "screencap", badge: "SCR", isAvailable: false),
            LibraryItem(name: "cam2", badge: "IP", isAvailable: false),
            LibraryItem(name: "DVC100", badge: "CAP", isAvailable: false),
            LibraryItem(name: "amiga titler", badge: "EMU", isAvailable: false)
        ]
    }
}
