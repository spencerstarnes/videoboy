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

    /// The ⇅ keys that sit on the joins between A/B and between C/D. Owned here so the
    /// grid can place them on the seam and the controller can wire them, the same way
    /// every other control in the window is reached.
    let swapAB = SeamSwapKey(upper: "A", lower: "B")
    let swapCD = SeamSwapKey(upper: "C", lower: "D")
    let subMixOneBody: PreviewPanelBody
    let subMixTwoBody: PreviewPanelBody
    let programBody: PreviewPanelBody
    let faderABBody: FaderPanelBody
    let faderCDBody: FaderPanelBody
    let faderOneTwoBody: FaderPanelBody
    let settingsBarBody: SettingsBarPanelBody
    let effectsOneBody: EffectChainPanelBody
    let effectsTwoBody: EffectChainPanelBody
    /// The library, shared by all three panels that show it.
    let library: LibraryModel

    /// The emulated machine — one for the app, driven from the EMU tab.
    let emulator: EmulatorController
    /// The EMU tab's view, so the shell can reach it when the machine changes.
    let emuBrowser: EmuBrowserView

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
        // Each source's fill key sits at the right end of its own title bar.
        for (panel, body) in [(sourceA, bodyA), (sourceB, bodyB), (sourceC, bodyC), (sourceD, bodyD)] {
            panel.setHeaderAccessory(body.fillKey)
        }

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
            caption: "", showsBlendControls: true, recordLabel: "1",
            offersDataBurn: true)
        subMixTwoBody = PreviewPanelBody(
            caption: "", showsBlendControls: true, recordLabel: "2",
            offersDataBurn: true)
        programBody = PreviewPanelBody(
            caption: "", showsBlendControls: true, recordLabel: "P")

        // Named for what they ARE rather than for the routing into them. "A ▸ B" on
        // the preview and "A → B Fader" on the panel beneath said the same thing
        // twice, and neither said which sub mix you were looking at.
        subMixOne = PanelView(title: "A/B Sub Mix", bus: .one, body: subMixOneBody)
        subMixTwo = PanelView(title: "C/D Sub Mix", bus: .two, body: subMixTwoBody)
        program = PanelView(title: "Program", bus: .program, body: programBody)

        // MARK: Faders
        faderABBody = FaderPanelBody(
            leftLabel: "A", rightLabel: "B",
            leftColor: Theme.Color.busOne, rightColor: Theme.Color.textSecondary,
            includesSwap: false,
            includesABRoll: FeatureFlag.abRoll.isOn
        )
        faderCDBody = FaderPanelBody(
            leftLabel: "C", rightLabel: "D",
            leftColor: Theme.Color.busTwo, rightColor: Theme.Color.textSecondary,
            includesSwap: false,
            includesABRoll: FeatureFlag.abRoll.isOn
        )
        faderOneTwoBody = FaderPanelBody(
            // The ends match the keys above them. Saying "ONE" under a key marked "1"
            // is two names for one bus in the space of a centimetre.
            leftLabel: "1", rightLabel: "2",
            // The PROGRAM fader's halves take the panel BACKGROUND colours of the two
            // sides they select between, not the full-strength bus colours. This
            // fader chooses between two windows; matching what those windows are
            // painted says so more directly than a saturated stripe.
            leftColor: Theme.Color.panelFill(forBus: Theme.Color.busOne),
            rightColor: Theme.Color.panelFill(forBus: Theme.Color.busTwo),
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
        faderOneTwo = PanelView(title: "Program", bus: .program, body: faderOneTwoBody)

        // MARK: Effect chains
        //
        // Empty here: the cards ARE the engine's chains (EffectChain), built from the
        // module catalogue by ShellController — every card the same way, whatever the
        // module is (ISF-PLAN M7). A shell with no controller has no chains to show.
        effectsOneBody = EffectChainPanelBody(effects: [])
        effectsTwoBody = EffectChainPanelBody(effects: [])

        effectsOne = PanelView(title: "A/B FX", bus: .one, body: effectsOneBody)
        effectsTwo = PanelView(title: "C/D FX", bus: .two, body: effectsTwoBody)

        // MARK: Libraries
        // The sub-mix libraries start from what is actually in samples/; the central
        // browser shows the full inventory of source kinds, with unbuilt ones greyed.
        // ONE library, shown three times. The two sub-mix panels differ only in where a
        // double-click sends the clip — A/B on the left, C/D on the right — so their
        // CONTENTS must be identical. They were separate copies before, which meant a
        // folder dropped on the left never appeared on the right.
        let library = LibraryModel()
        library.setItems(PanelSet.sampleLibraryItems())
        self.library = library

        libraryOneBody = LibraryPanelBody(
            model: library, columns: 3, showsTabs: false, playlistChannels: ["A", "B"])
        libraryTwoBody = LibraryPanelBody(
            model: library, columns: 3, showsTabs: false, playlistChannels: ["C", "D"])
        // The emulated machine, and the EMU tab that drives it. Owned here because the
        // asset browser is built here and the tab has to exist when it is.
        emulator = EmulatorController()
        let emuBrowser = EmuBrowserView(controller: emulator)
        self.emuBrowser = emuBrowser

        assetBrowserBody = LibraryPanelBody(
            model: library, columns: 6, showsTabs: true, emuView: emuBrowser)
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
            let badge = (file as NSString).pathExtension.uppercased()
            // Duration from the manifest's frame count, which is already there — the
            // alternative is opening every file at launch to ask, which is a lot of
            // I/O for a column in a list.
            let frames = entry["frameCount"] as? Int
            let rate = (entry["frameRate"] as? Double)
                ?? ((entry["standard"] as? String) == "PAL" ? 25.0 : 30000.0 / 1001.0)
            let duration = frames.map { Double($0) / rate }

            return LibraryItem(
                name: file, badge: badge, isAvailable: true,
                url: RepoPaths.samples.appendingPathComponent(file),
                duration: duration)
        }
    }

    /// The live H.264 datamosh card's title (the catalogue's name for the module).
    static let datamoshCardName = "Datamosh · H.264"

    /// The bitstream corruptor's card (MPEG) — the one card that is not a chain module.
    ///
    /// It is a FIXED stage, not a layer: it rewrites the bitstream before decode, on the
    /// source itself, so it cannot move in the chain and has no bus copy (ISF-PLAN §4).
    ///
    /// WHY IT IS OMITTED AND NOT GREYED. The house rule is that unfinished work renders
    /// DISABLED rather than absent. This is the opposite case: the effect is FINISHED,
    /// and it is out because it cannot currently be judged — there is no analog chain
    /// here to see it on. Nothing is deleted: node, shader, parameters
    /// and tests are intact behind `FeatureFlag.bitstreamCorruptor`, and
    /// `VIDEOBOY_FLAGS=bitstreamCorruptor` brings the card back for one launch.
    static let corruptorCardName = "MPEG · corruptor"

    static func corruptorCard(channels: [String]) -> EffectCardModel? {
        guard FeatureFlag.bitstreamCorruptor.isOn else { return nil }
        return
            EffectCardModel(
                name: corruptorCardName,
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
                channelOptions: channels
            )
    }

}
