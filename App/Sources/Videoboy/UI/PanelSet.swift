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
    let libraryOneBody: LibraryPanelBody
    let libraryTwoBody: LibraryPanelBody
    let assetBrowserBody: LibraryPanelBody

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
        // The three composites each carry a blend mode and a layer opacity (SPEC 12).
        // No caption on any of the three.
        //
        // These read "100 IRE", "7.5 IRE" and "720×480" — lifted from the mockup,
        // where they were sample text. Nothing measured them: the first two are
        // simply the two ends of the NTSC legal range printed as decoration, one on
        // each panel, and the third stated a frame size that is fixed for the whole
        // app and identical on all three. Three labels saying three different KINDS
        // of thing, none of them true of the picture underneath. The scopes report
        // levels, and they do it by measuring.
        subMixOneBody = PreviewPanelBody(
            caption: "", showsBlendControls: true, recordLabel: "1")
        subMixTwoBody = PreviewPanelBody(
            caption: "", showsBlendControls: true, recordLabel: "2")
        programBody = PreviewPanelBody(
            caption: "", showsBlendControls: true, recordLabel: "P")

        // Named for what they ARE rather than for the routing into them. "A ▸ B" on
        // the preview and "A → B Fader" on the panel beneath said the same thing
        // twice, and neither said which sub mix you were looking at.
        subMixOne = PanelView(title: "A/B Sub Mix", bus: .one, body: subMixOneBody)
        subMixTwo = PanelView(title: "C/D Sub Mix", bus: .two, body: subMixTwoBody)
        program = PanelView(title: "Program", body: programBody)

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
            // The ends match the keys above them. Saying "ONE" under a key marked "1"
            // is two names for one bus in the space of a centimetre.
            leftLabel: "1", rightLabel: "2",
            leftColor: Theme.Color.busOne, rightColor: Theme.Color.busTwo,
            includesSwap: true,
            // Numbered, the way a switcher numbers its buses — and the way the record
            // indicators on the two sub-mix previews already read.
            leftKeyLabel: "1", rightKeyLabel: "2"
        )
        // The fader sits directly under the preview it drives, and its bus keys are
        // labelled with the sources. Repeating the routing in the title was the third
        // time the same fact appeared in one column.
        faderAB = PanelView(title: "A/B", bus: .one, body: faderABBody)
        faderCD = PanelView(title: "C/D", bus: .two, body: faderCDBody)
        faderOneTwo = PanelView(title: "Program", body: faderOneTwoBody)

        // MARK: Effect chains
        //
        // The DV DIF corruptor is the one effect that is real in this phase — it is
        // the wedge. Everything else is present and disabled so the chain's shape is
        // visible from the first run.
        effectsOneBody = EffectChainPanelBody(effects: [
            EffectCardModel(
                name: "Transform",
                isEnabled: false,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "scale", code: ParamCode.scale.rawValue,
                                         value: 0.231, enabled: true),
                    EffectParameterModel(name: "rotate", code: ParamCode.rotation.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "flip H", code: ParamCode.flipHorizontal.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "flip V", code: ParamCode.flipVertical.rawValue,
                                         value: 0.0, enabled: true)
                ],
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "DV · DIF corruptor",
                // OFF, like every effect except the grade. The wedge is the loudest
                // thing in the app and it should be something you switch on, not
                // something you discover is already on.
                isEnabled: false,
                isImplemented: FeatureFlag.bitstreamCorruptor.isOn,
                parameters: [
                    EffectParameterModel(name: "amount", code: ParamCode.corruptAmount.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "mode", code: ParamCode.corruptMode.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "rate", code: ParamCode.corruptRate.rawValue,
                                         value: 0.25, enabled: true)
                ],
                // SPEC 2's chFX runs once per CHANNEL — A and B each carry their own
                // wedge. This one card reaches whichever of the two is selected here,
                // rather than being hardwired to A the way it was before this could
                // be switched at all.
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "Composite · NTSC",
                isEnabled: false,
                isImplemented: FeatureFlag.compositeCodec.isOn,
                parameters: [
                    EffectParameterModel(name: "path", code: ParamCode.compositePath.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "crawl", code: ParamCode.compositeCrawl.rawValue,
                                         value: 0.6, enabled: true),
                    EffectParameterModel(name: "bleed", code: ParamCode.chromaBleed.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "luma bw", code: ParamCode.lumaBandwidth.rawValue,
                                         value: 0.7, enabled: true),
                    EffectParameterModel(name: "wobble", code: ParamCode.tbcWobble.rawValue,
                                         value: 0.2, enabled: true),
                    EffectParameterModel(name: "head sw", code: ParamCode.headSwitchingNoise.rawValue,
                                         value: 0.3, enabled: true),
                    EffectParameterModel(name: "chroma", code: ParamCode.chromaSubsampling.rawValue,
                                         value: 1.0, enabled: true),
                    EffectParameterModel(name: "gen", code: ParamCode.compositeGeneration.rawValue,
                                         value: 0.0, enabled: true)
                ],
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "Colour",
                // ON by default, unlike every other effect here. A grade at its
                // neutral settings changes nothing and costs nothing — the node skips
                // its render pass entirely when it is neutral — so there is no reason
                // to make someone switch it on before they can touch a fader. Every
                // other card in this chain alters the picture the moment it is armed,
                // which is why they all start off.
                isEnabled: true,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "bright", code: ParamCode.brightness.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "contrast", code: ParamCode.contrast.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "sat", code: ParamCode.saturation.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "shadow", code: ParamCode.shadow.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "highlt", code: ParamCode.highlight.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "black", code: ParamCode.blackLevel.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "white", code: ParamCode.whiteLevel.rawValue,
                                         value: 1.0, enabled: true),
                    EffectParameterModel(name: "gamma", code: ParamCode.gamma.rawValue,
                                         value: 0.231, enabled: true)
                ],
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "Echo / Trails",
                isEnabled: false,
                isImplemented: FeatureFlag.feedback.isOn,
                parameters: [
                    EffectParameterModel(name: "decay", code: ParamCode.echoDecay.rawValue,
                                         value: 0.8, enabled: true),
                    EffectParameterModel(name: "length", code: ParamCode.trailLength.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "thresh", code: ParamCode.echoThreshold.rawValue,
                                         value: 0.15, enabled: true)
                ],
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "Feedback",
                isEnabled: false,
                isImplemented: FeatureFlag.feedback.isOn,
                parameters: [
                    EffectParameterModel(name: "gain", code: ParamCode.feedbackGain.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "delay", code: ParamCode.feedbackDelayFrames.rawValue,
                                         value: 0.02, enabled: true),
                    EffectParameterModel(name: "zoom", code: ParamCode.feedbackZoom.rawValue,
                                         value: 0.52, enabled: true),
                    EffectParameterModel(name: "rotate", code: ParamCode.feedbackRotate.rawValue,
                                         value: 0.5, enabled: true)
                ],
                channelOptions: ["A", "B"]
            ),
            EffectCardModel(
                name: "MX-1",
                isEnabled: false,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "effect", code: ParamCode.mx1Effect.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "amount", code: ParamCode.mx1Amount.rawValue,
                                         value: 0.5, enabled: true)
                ]
            )
        ])

        // Sub Mix TWO's chain: the same effects, on its own instances, so the two
        // buses can carry different looks at once.
        effectsTwoBody = EffectChainPanelBody(effects: [
            EffectCardModel(
                name: "Transform",
                isEnabled: false,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "scale", code: ParamCode.scale.rawValue,
                                         value: 0.231, enabled: true),
                    EffectParameterModel(name: "rotate", code: ParamCode.rotation.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "flip H", code: ParamCode.flipHorizontal.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "flip V", code: ParamCode.flipVertical.rawValue,
                                         value: 0.0, enabled: true)
                ],
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "DV · DIF corruptor",
                // OFF, like every effect except the grade. The wedge is the loudest
                // thing in the app and it should be something you switch on, not
                // something you discover is already on.
                isEnabled: false,
                isImplemented: FeatureFlag.bitstreamCorruptor.isOn,
                parameters: [
                    EffectParameterModel(name: "amount", code: ParamCode.corruptAmount.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "mode", code: ParamCode.corruptMode.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "rate", code: ParamCode.corruptRate.rawValue,
                                         value: 0.25, enabled: true)
                ],
                // This chain had NO wedge card at all before this — channel C's
                // corruption was wired all the way through the registry and never
                // reachable from anywhere in the window. D reaches it too, by the
                // selector below.
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "Composite · NTSC",
                isEnabled: false,
                isImplemented: FeatureFlag.compositeCodec.isOn,
                parameters: [
                    EffectParameterModel(name: "path", code: ParamCode.compositePath.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "crawl", code: ParamCode.compositeCrawl.rawValue,
                                         value: 0.6, enabled: true),
                    EffectParameterModel(name: "bleed", code: ParamCode.chromaBleed.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "wobble", code: ParamCode.tbcWobble.rawValue,
                                         value: 0.2, enabled: true)
                ],
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "Colour",
                // ON by default, unlike every other effect here. A grade at its
                // neutral settings changes nothing and costs nothing — the node skips
                // its render pass entirely when it is neutral — so there is no reason
                // to make someone switch it on before they can touch a fader. Every
                // other card in this chain alters the picture the moment it is armed,
                // which is why they all start off.
                isEnabled: true,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "bright", code: ParamCode.brightness.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "contrast", code: ParamCode.contrast.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "sat", code: ParamCode.saturation.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "shadow", code: ParamCode.shadow.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "highlt", code: ParamCode.highlight.rawValue,
                                         value: 0.5, enabled: true),
                    EffectParameterModel(name: "black", code: ParamCode.blackLevel.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "white", code: ParamCode.whiteLevel.rawValue,
                                         value: 1.0, enabled: true),
                    EffectParameterModel(name: "gamma", code: ParamCode.gamma.rawValue,
                                         value: 0.231, enabled: true)
                ],
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "Echo / Trails",
                isEnabled: false,
                isImplemented: FeatureFlag.feedback.isOn,
                parameters: [
                    EffectParameterModel(name: "decay", code: ParamCode.echoDecay.rawValue,
                                         value: 0.8, enabled: true),
                    EffectParameterModel(name: "length", code: ParamCode.trailLength.rawValue,
                                         value: 0.0, enabled: true)
                ],
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "Feedback",
                isEnabled: false,
                isImplemented: FeatureFlag.feedback.isOn,
                parameters: [
                    EffectParameterModel(name: "gain", code: ParamCode.feedbackGain.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "zoom", code: ParamCode.feedbackZoom.rawValue,
                                         value: 0.52, enabled: true)
                ],
                channelOptions: ["C", "D"]
            ),
            EffectCardModel(
                name: "MX-1",
                isEnabled: false,
                isImplemented: true,
                parameters: [
                    EffectParameterModel(name: "effect", code: ParamCode.mx1Effect.rawValue,
                                         value: 0.0, enabled: true),
                    EffectParameterModel(name: "amount", code: ParamCode.mx1Amount.rawValue,
                                         value: 0.5, enabled: true)
                ]
            )
        ])

        effectsOne = PanelView(title: "A/B FX", bus: .one, body: effectsOneBody)
        effectsTwo = PanelView(title: "C/D FX", bus: .two, body: effectsTwoBody)

        // MARK: Libraries
        // The sub-mix libraries start from what is actually in samples/; the central
        // browser shows the full inventory of source kinds, with unbuilt ones greyed.
        let sampleItems = PanelSet.sampleLibraryItems()
        libraryOneBody = LibraryPanelBody(
            items: sampleItems, columns: 3, showsTabs: false, playlistChannels: ["A", "B"])
        libraryTwoBody = LibraryPanelBody(
            items: sampleItems, columns: 3, showsTabs: false, playlistChannels: ["C", "D"])
        assetBrowserBody = LibraryPanelBody(
            items: sampleItems + PanelSet.futureSourceKinds(), columns: 6, showsTabs: true)
        // Bus-coloured like every other A/B and C/D panel. These two were the only
        // pair in the window carrying a bus in their NAME while showing none of the
        // colour that says which bus it is — so the one place you go to put a clip
        // on a bus was the one place that would not tell you which bus you were
        // looking at.
        libraryOne = PanelView(
            title: "A/B Library", bus: .one, body: libraryOneBody)
        libraryTwo = PanelView(
            title: "C/D Library", bus: .two, body: libraryTwoBody)
        assetBrowser = PanelView(title: "Asset Browser", body: assetBrowserBody)

        // MARK: Settings bar
        settingsBarBody = SettingsBarPanelBody(negotiatedMode: "not yet negotiated")
        // No header: this is a bar, not a panel. A title over it cost as much height
        // as the row itself and said nothing the controls do not.
        settingsBar = PanelView(title: "Output", showsHeader: false, body: settingsBarBody)
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
            return LibraryItem(
                name: file, badge: badge, isAvailable: true,
                url: RepoPaths.samples.appendingPathComponent(file))
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
