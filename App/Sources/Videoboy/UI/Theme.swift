//
//  Theme.swift — every radius, padding, gutter and colour, in one place.
//
//  Purpose : SPEC 14.4 requires the design tokens to live in a single file so the
//            density can be tightened later without touching layout code. Layout
//            code must read from here; no view may contain a literal spacing or
//            colour value.
//  Inputs  : none. The values come from docs/mockups/layout-v6.html, which is the
//            normative visual reference (SPEC 14).
//  Outputs : `Theme.*` constants consumed by every view in UI/.
//  Connects: MainWindowController, PanelView, and each panel's contents.
//  Extend  : add a token here and use it. If you find yourself typing a number into
//            a view, it belongs in this file instead.
//

import AppKit

/// Design tokens. `enum` with statics: a namespace, never instantiated.
enum Theme {

    // MARK: - Geometry
    //
    // The mockup's radii and padding are deliberately generous; SPEC 14.4 notes a
    // live control surface wants tighter geometry, and that dialling it in later is
    // expected. Changing these numbers is how that happens.

    enum Metrics {
        /// Corner radius of a panel box (`.box` in the mockup).
        static let panelCornerRadius: CGFloat = 8
        /// Corner radius of a push button (`.pb`).
        static let buttonCornerRadius: CGFloat = 6
        /// Gap between panels in the grid (`.panes { gap }`).
        static let panelGutter: CGFloat = 7
        /// Padding around the whole panel grid (`.panes { padding }`).
        static let gridPadding: CGFloat = 8
        /// Horizontal and vertical padding inside a panel header (`.boxh`).
        static let panelHeaderPaddingX: CGFloat = 8
        static let panelHeaderPaddingY: CGFloat = 4
        /// Padding inside a panel body.
        static let panelBodyPadding: CGFloat = 6
        /// Spacing between controls sitting on one row.
        static let controlSpacing: CGFloat = 6
        /// Height of the transport toolbar above the grid.
        static let toolbarHeight: CGFloat = 44
        /// Height of the status bar below the grid.
        static let statusBarHeight: CGFloat = 22
        /// Height of a panel header.
        static let panelHeaderHeight: CGFloat = 22
        /// Height of the record/stream/output/toggles bar.
        static let settingsBarHeight: CGFloat = 34
        /// Diameter of the bus-identity dot in a panel header.
        static let busDotDiameter: CGFloat = 6
        /// Thickness of hairline separators.
        static let hairline: CGFloat = 1
        /// Video previews are 4:3 — standard definition, not 16:9 (SPEC 3).
        static let previewAspectRatio: CGFloat = 4.0 / 3.0
        /// Side of a thumbnail in the library and browser grids.
        static let thumbnailSide: CGFloat = 54
    }

    // MARK: - Grid proportions
    //
    // Straight from SPEC 14.1 and the mockup's grid-template. Five columns, five
    // rows, expressed as relative weights.

    enum Grid {
        /// Column weights, left to right: sources, ONE, program, TWO, sources.
        static let columnWeights: [CGFloat] = [0.9, 2.0, 2.1, 2.0, 0.9]
        /// Row weights, top to bottom.
        static let rowWeights: [CGFloat] = [1.05, 1.05, 0.6, 1.75, 0.55]
    }

    // MARK: - Breakpoints
    //
    // SPEC 14.4: wide shows everything, compact collapses the outer columns to
    // rails, narrow keeps only program + faders + settings. Reflow, never scroll.

    enum Breakpoint {
        /// At or above this width the full five-column grid is shown.
        static let wide: CGFloat = 1180
        /// Between `compact` and `wide` the outer source/FX columns become rails.
        static let compact: CGFloat = 900
        /// The window refuses to go below this; narrow layout applies here.
        static let minimumWindowWidth: CGFloat = 720
        static let minimumWindowHeight: CGFloat = 520
    }

    // MARK: - Colour
    //
    // Amber and cyan are bus identity for ONE and TWO only, never chrome (SPEC 14.3).
    // Everything else defers to the system so dark mode and accent colour work.

    enum Color {
        /// Background behind the panel grid (`--content`).
        static let content = NSColor(srgbRed: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x20 / 255.0, alpha: 1)
        /// Panel fill (`--box`).
        static let panelFill = NSColor(white: 1.0, alpha: 0.045)
        /// Slightly darker fill for nested areas (`--box2`).
        static let panelFillNested = NSColor(white: 1.0, alpha: 0.028)
        /// Panel border (`--boxln`).
        static let panelBorder = NSColor(white: 1.0, alpha: 0.10)
        /// Hairline separator (`--sep`).
        static let separator = NSColor(white: 1.0, alpha: 0.10)
        /// Toolbar and status bar background (`--bar`).
        static let bar = NSColor(srgbRed: 0x3a / 255.0, green: 0x3a / 255.0, blue: 0x3c / 255.0, alpha: 1)

        /// Primary, secondary and tertiary text (`--t1`, `--t2`, `--t3`).
        static let textPrimary = NSColor(white: 1.0, alpha: 0.88)
        static let textSecondary = NSColor(white: 1.0, alpha: 0.56)
        static let textTertiary = NSColor(white: 1.0, alpha: 0.30)

        /// Sub Mix ONE identity, amber (`--one`).
        static let busOne = NSColor(srgbRed: 0xe3 / 255.0, green: 0xa5 / 255.0, blue: 0x3a / 255.0, alpha: 1)
        /// Sub Mix TWO identity, cyan (`--two`).
        static let busTwo = NSColor(srgbRed: 0x54 / 255.0, green: 0xc2 / 255.0, blue: 0xcf / 255.0, alpha: 1)

        /// Active/selected state. The system accent, so it follows the user's setting.
        static let accent = NSColor.controlAccentColor

        /// Highlight drawn over every mappable control while Shift is held (SPEC 7).
        static let detectHighlight = NSColor.systemYellow

        /// Fill behind a video preview that has no source yet.
        static let previewEmpty = NSColor(white: 0.07, alpha: 1)
    }

    // MARK: - Type

    enum Font {
        /// Panel titles.
        static let panelTitle = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// Small labels next to controls.
        static let label = NSFont.systemFont(ofSize: 10, weight: .regular)
        /// Even smaller labels (mapping badges, param codes).
        static let tinyLabel = NSFont.systemFont(ofSize: 9, weight: .regular)
        /// Monospaced readouts: param codes, negotiated modes, fps.
        static let mono = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        /// The large tempo readout in the toolbar.
        static let tempo = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
    }
}
