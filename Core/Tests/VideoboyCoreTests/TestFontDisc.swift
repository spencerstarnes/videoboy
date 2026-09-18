//
//  TestFontDisc.swift — one shared answer to "what fonts does this machine have?"
//

import VideoboyCore

/// The fonts as they really are on the Scala disc, for tests that need a read drive.
///
/// Amiga fonts are bitmaps at fixed sizes. A panel with no catalogue keeps its size
/// control SHUT, because a size the face does not have drops Scala's screen — so a test
/// that exercises the size control has to say which drive it is pretending to have read.
enum TestFontDisc {
    static let fonts = [
        ScalaFont(name: "BetonC", sizes: [44]),
        ScalaFont(name: "Compact", sizes: [16, 24, 31, 64]),
        ScalaFont(name: "Didot", sizes: [28, 56]),
        ScalaFont(name: "Franklin", sizes: [18, 23, 36, 72]),
        ScalaFont(name: "NewsGothic", sizes: [56, 114])
    ]

    /// A panel that behaves as though the disc had been read.
    static func panel() -> ScalaTitlerPanel {
        let panel = ScalaTitlerPanel()
        panel.fontCatalogue = fonts
        return panel
    }

    /// Franklin's index in the catalogue above.
    static let franklin = 3
}
