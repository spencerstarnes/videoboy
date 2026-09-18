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
        /// Corner radius of a panel box.
        ///
        /// Tighter than the mockup's 8: SPEC 14.4 says the mockup's radii are larger
        /// than ideal and expects them dialled in, and a smaller radius is what lets
        /// adjacent panels butt together without a visible pinch at the seam.
        static let panelCornerRadius: CGFloat = 5
        /// Corner radius of a push button (`.pb`).
        static let buttonCornerRadius: CGFloat = 5
        /// Gap between panel GROUPS in the grid.
        ///
        /// Panels that belong together have no gap at all and share a hairline
        /// instead — the Resolve/FCP approach, where space means "these are separate
        /// things" rather than being sprinkled everywhere. See PanelGridView.
        static let panelGutter: CGFloat = 5
        /// Padding around the whole panel grid.
        static let gridPadding: CGFloat = 5
        /// Horizontal and vertical padding inside a panel header (`.boxh`).
        static let panelHeaderPaddingX: CGFloat = 8
        static let panelHeaderPaddingY: CGFloat = 4
        /// Padding inside a panel body.
        static let panelBodyPadding: CGFloat = 6
        /// Spacing between controls sitting on one row.
        static let controlSpacing: CGFloat = 6
        /// Height of the transport toolbar above the grid.
        static let toolbarHeight: CGFloat = 52
        /// Height of the recessed transport cluster inside it.
        static let transportDisplayHeight: CGFloat = 42
        /// Height of the status bar below the grid.
        static let statusBarHeight: CGFloat = 22
        /// Height of a panel header.
        static let panelHeaderHeight: CGFloat = 22
        /// Height of the record/stream/output/toggles bar.
        static let settingsBarHeight: CGFloat = 26
        /// Diameter of the bus-identity dot in a panel header.
        static let busDotDiameter: CGFloat = 6
        /// Thickness of hairline separators.
        static let hairline: CGFloat = 1
        /// Video previews are 4:3 — standard definition, not 16:9 (SPEC 3).
        static let previewAspectRatio: CGFloat = 4.0 / 3.0
        /// Side of a thumbnail in the library and browser grids.
        ///
        /// Every item is exactly this wide, so the grid is a grid: items of differing
        /// widths read as clutter however neatly they are spaced.
        static let thumbnailSide: CGFloat = 52
        /// Height of a thumbnail's image area. 4:3, matching the video it stands for.
        static let thumbnailImageHeight: CGFloat = 39
        /// Gap between items in a library grid. Tight on purpose.
        static let thumbnailGap: CGFloat = 3
        /// Height of a caption under a thumbnail.
        static let thumbnailCaptionHeight: CGFloat = 11
        /// Width of the drag handle that reorders effects.
        static let dragHandleWidth: CGFloat = 12
        /// Width of a numeric readout beside a fader.
        ///
        /// Popups are `.small`, never `.mini`: a mini popup's text is genuinely
        /// unreadable at a glance, and a selector you cannot read is not a control.
        ///
        /// Fixed rather than fitted: a readout that resizes as its digits change
        /// makes the whole row twitch while a fader is being dragged, which is
        /// exactly when it needs to be readable.
        static let valueReadoutWidth: CGFloat = 32
    }

    // MARK: - Pulse
    //
    // How strongly the window chrome responds to the clock. Both are small on
    // purpose: this is meant to be felt in peripheral vision while watching the
    // picture, not looked at.

    // MARK: - Bus buttons
    //
    // Sized to be hit without looking. A switcher's buttons are about a centimetre
    // across because that is what a hand needs; these are as close to that as the
    // panel allows.
    enum BusButton {
        static let width: CGFloat = 40
        static let height: CGFloat = 30
        static let cornerRadius: CGFloat = 3
        /// The highlight along the top edge that gives the key its height.
        static let lipHeight: CGFloat = 4
    }

    // MARK: - Option buttons
    //
    // Sized from AppKit's own mini metrics (a mini button is 16pt) so these sit
    // correctly beside the system controls they share a bar with, rather than to
    // numbers invented for the occasion.
    enum OptionButton {
        static let height: CGFloat = 17
        static let horizontalPadding: CGFloat = 7
        static let cornerRadius: CGFloat = 3
    }

    // MARK: - Bar spacing
    //
    // Cocoa's guidance: related controls sit close, unrelated groups sit apart. The
    // old bar used one spacing for both, so nothing read as grouped and the whole
    // strip spread out.
    enum BarSpacing {
        /// Between controls that belong together.
        static let withinGroup: CGFloat = 4
        /// Between one group and the next, either side of a divider.
        static let betweenGroups: CGFloat = 14
    }

    enum Pulse {
        /// Peak strength of the per-beat pulse, as a blend fraction.
        static let beatStrength: Double = 0.06
        /// Peak strength of the tempo-change flash.
        static let flashStrength: Double = 0.22
        /// How fast that flash fades, per 30 Hz tick. About two-thirds of a second.
        static let flashDecayPerFrame: Double = 0.05

        /// How visible a driven parameter's outline is between beats.
        ///
        /// Never zero: the mark must say "this is driven" while the transport is
        /// stopped, and a parameter that only shows its driver while the music runs
        /// would be silent exactly when you are setting the patch up.
        static let drivenBaseAlpha: Double = 0.34
        static let drivenLineWidth: CGFloat = 1.5
    }

    // MARK: - Record
    //
    // Recording lives at the top right (not in the bottom bar as the original mockup
    // had it): it is the control you must be able to hit without hunting, and the one
    // whose state you must be able to read from across the room.

    enum Record {
        static let buttonDiameter: CGFloat = 26

        /// The per-preview arm indicator: a dot plus its channel letter.
        static let miniWidth: CGFloat = 26
        static let miniHeight: CGFloat = 14
        static let miniDotDiameter: CGFloat = 7
        /// How dim an armed dot gets at the bottom of its pulse. Never fully out —
        /// an indicator that disappears reads as "not armed".
        static let miniPulseFloor: Double = 0.35
        /// Beats per pulse. Two, not one: at one beat it flickers and fights the
        /// picture; at two it is unmistakably deliberate and still locked to tempo.
        static let pulseBeats: Double = 2.0
    }

    // MARK: - Fader
    //
    // The custom fader's geometry (VBFader). A DJ fader reads at a glance because the
    // cap is a solid object overhanging a visible slot; these numbers are what produce
    // that, and they are the ones to change if it wants to be chunkier still.

    enum Fader {
        /// Thickness of the slot. Thick enough to see the fill from across a room.
        static let trackHeight: CGFloat = 4
        /// Cap width, across the direction of travel.
        static let capWidth: CGFloat = 11
        /// Cap height. Deliberately larger than `trackHeight` — the overhang is the
        /// whole point, and it is what `NSSlider` will not give.
        static let capHeight: CGFloat = 13
        /// How much the cap grows while being dragged, for feedback under the finger.
        static let capDragGrowth: CGFloat = 2
        static let capCornerRadius: CGFloat = 2.5
        /// The line down the middle of the cap, as a real fader cap has.
        static let capLineWidth: CGFloat = 1
        static let capLineInset: CGFloat = 3.5
        /// Opacity of the whole control when disabled.
        static let disabledAlpha: CGFloat = 0.35
        /// Fraction of the range one arrow-key press moves.
        static let keyboardStep: Double = 0.01
        /// Height of the taller crossfader used in the fader panels. Must leave room
        /// for the track PLUS the cap's overhang on both sides, or the cap is clipped.
        static let crossfaderHeight: CGFloat = 32
        /// How strongly a tinted track shows its bus colour. Low: it must say which
        /// way you are heading without competing with the picture above it.
        static let trackTintAlpha: CGFloat = 0.30
        /// Track thickness for the primary crossfader — the heaviest control in the
        /// window, and the one a hand finds without looking.
        static let primaryTrackHeight: CGFloat = 22

        /// How far the cap stands proud of its track, top and bottom.
        ///
        /// A constant rather than a fixed cap height, so growing a track can never
        /// again leave its cap sunk into the slot.
        static let capOverhang: CGFloat = 6
        /// Height of the compact fader used in a shuttle strip, where the scrub track
        /// is a readout more than a control and must not dominate the row.
        static let compactHeight: CGFloat = 9
    }

    // MARK: - Grid proportions
    //
    // Straight from SPEC 14.1 and the mockup's grid-template. Five columns, five
    // rows, expressed as relative weights.

    enum Grid {
        /// Column weights, left to right: sources, ONE, program, TWO, sources.
        ///
        /// The outer columns are a little wider than the mockup's 0.9: they carry the
        /// FX chains, whose parameter names and codes were truncating. Joining the
        /// A/B and C/D panels reclaimed the gutters that pay for it.
        /// The three inner columns are EQUAL. The centre used to be a hair wider
        /// (2.05 against 2.0), which was invisible until the preview panels became
        /// 4:3: their height is derived from one column's width, so a column that is
        /// 2.5% narrower produces a panel that is 2.5% off the ratio. Equal columns
        /// make all three previews the same shape, which is the point of fixing them
        /// to 4:3 at all.
        static let columnWeights: [CGFloat] = [1.05, 2.0, 2.0, 2.0, 1.05]
        /// Row weights, top to bottom.
        /// The preview rows are taller than the mockup's: the source panels now carry
        /// a shuttle, a step-timing picker and a source selector under their preview,
        /// and cramming those into the old height left every one of them too small to
        /// read. The library row gives up the space — it is a grid and scrolls.
        // The last row is the output bar, which is one 26pt strip with no header. It
        // had been given nearly twice the height it can use, and the slack went to
        // empty space inside the panel — which is most of what made it look chunky.
        // The height it gives back goes to the previews and the libraries.
        /// Rows 0 and 1 are the preview band, whose height is DERIVED from the
        /// column width so the preview panels come out 4:3. Their weights here only
        /// decide how that band is split between them. Rows 2-4 share what is left,
        /// in the proportions given.
        /// Row weights. The LAST entry is ignored for sizing — the output bar is a
        /// fixed height (`outputBarHeight`), not a share of what is left — but it
        /// stays in the list so the row count and the gutter arithmetic still line up.
        // Row 2 (the faders) came down from 0.6 and row 3 (the libraries) went up by
        // the same amount. A fader panel holds a header, one row of keys and one
        // fader, and at 0.6 roughly a third of it was empty below the track — while
        // the libraries underneath were the one place in the window that can always
        // use more height, because they are grids that scroll.
        static let rowWeights: [CGFloat] = [1.0, 1.0, 0.44, 1.61, 0.31]

        /// Height of the output bar, which holds one row of 22pt controls and a
        /// little padding. Fixed rather than weighted: as a weight it grew with the
        /// window and spent the difference on empty space.
        static let outputBarHeight: CGFloat = 34

        /// Least share of the height above the output bar that the preview band takes.
        ///
        /// ZERO, deliberately, which means the band is exactly 4:3 of one column's
        /// width and never taller.
        ///
        /// This briefly ran at 0.48 to make the source monitors bigger, and that was
        /// wrong for THIS app. Every texture in the graph is 720x480 (see
        /// `RenderContext`: "Project geometry. Every texture in the graph is this
        /// size"), the signal in and out is SD NTSC, and a source node's output is
        /// already fitted into that frame. So all seven preview panels show 4:3
        /// content, always — and a panel taller than 4:3 is not a trade, it is
        /// permanent black bars that nothing will ever fill.
        ///
        /// The height the source monitors needed came out of their own chrome
        /// instead. Left here as a deliberate zero rather than deleted, because the
        /// next person to think "the previews could be taller" should find the reason
        /// they are not.
        static let previewBandShare: CGFloat = 0

        /// The least the rows below the previews may be squeezed to.
        ///
        /// A short window would otherwise let 4:3 previews push the faders, the
        /// libraries and the output bar off the bottom. A squashed preview is
        /// recoverable; controls you cannot reach are not.
        static let minimumLowerRowsHeight: CGFloat = 250

        /// Column weight of a folded-away column — just enough for its rail.
        static let railWeight: CGFloat = 0.14

        /// Height of the horizontal strip a folded group leaves behind when its
        /// sibling has taken its cells. Tall enough to click without aiming, short
        /// enough that handing the space over was still worth doing.
        static let railStripHeight: CGFloat = 20
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

        /// `panelFill` already composited over the canvas, as an OPAQUE colour.
        ///
        /// Panels were drawn with the translucent fill straight onto a canvas that
        /// pulses, so every panel pulsed with it — the beat showed up inside the
        /// windows instead of only in the gutters between them. An opaque panel is
        /// what confines the pulse to the space behind everything.
        static let panelFillOpaque: NSColor = content.blended(
            withFraction: 0.045, of: .white) ?? content
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

        /// Sub Mix ONE identity.
        ///
        /// ── THE THREE BRAND HUES ────────────────────────────────────────────────
        ///
        /// From samples/COLORS.png: magenta #CC53C4, aqua #ACE4EA, yellow #F8E85F.
        /// Measured rather than eyeballed, and the measurement said something useful —
        /// the app's existing cyan is 186.3° and the brand aqua is 185.8°, which is the
        /// same hue. The palette came OUT of this window, so two of the three clusters
        /// barely move and the third gains a colour it never had.
        ///
        /// Hue from the brand, SATURATION AND VALUE FROM THE APP. The bars are swatches
        /// at full strength; a panel wearing that would be a panel you look at instead
        /// of through. This was amber at 38°/0.74/0.89 and is the brand yellow's 53.7°
        /// at the same 0.74/0.89 — a lemon rather than an orange, at exactly the
        /// weight the window already carried.
        static let busOne = NSColor(srgbRed: 0xe3 / 255.0, green: 0xd1 / 255.0, blue: 0x39 / 255.0, alpha: 1)
        /// How much of a bus's colour a panel belonging to it carries. Very low:
        /// enough to group the windows by eye, not enough to tint the picture.
        static let busTintStrength: CGFloat = 0.055

        /// The BACKGROUND a panel belonging to a bus actually ends up painted.
        ///
        /// One place, so the Program fader's two halves can be the same colour as the
        /// two panels they represent rather than a full-strength bus colour that
        /// merely gestures at them. PanelView reads this too, so the fader and the
        /// panel cannot drift apart.
        static func panelFill(forBus bus: NSColor?) -> NSColor {
            guard let bus else { return panelFillOpaque }
            return panelFillOpaque.blended(withFraction: busTintStrength, of: bus)
                ?? panelFillOpaque
        }

        /// Sub Mix TWO identity, the brand aqua. Unchanged — it was already this hue.
        static let busTwo = NSColor(srgbRed: 0x54 / 255.0, green: 0xc3 / 255.0, blue: 0xcf / 255.0, alpha: 1)

        /// PROGRAM's identity, the brand magenta.
        ///
        /// The third bar had nowhere to go, and Program was the one vertical cluster
        /// with no colour of its own — so the two facts answer each other.
        ///
        /// Desaturated to 0.45 rather than the swatch's 0.59. The tint strength is the
        /// same 5.5% for all three buses, but equal alpha is not equal WEIGHT: magenta
        /// carries further against a neutral dark panel than a yellow or an aqua does,
        /// and at the swatch's saturation the Program column read as purple while its
        /// neighbours read as barely tinted. The hue is the brand's; the weight matches
        /// the room.
        static let busProgram = NSColor(srgbRed: 0xd1 / 255.0, green: 0x73 / 255.0, blue: 0xca / 255.0, alpha: 1)

        /// Active/selected state. The system accent, so it follows the user's setting.
        static let accent = NSColor.controlAccentColor

        /// Highlight drawn over every mappable control while Shift is held (SPEC 7).
        static let detectHighlight = NSColor.systemYellow

        /// On air. Red means this everywhere in broadcast, and it is not used for
        /// anything else in this window.
        /// Animation. The span between a fader's two sweep marks, and the pulsing
        /// outline on every fader that could take one while the gesture is held.
        ///
        /// Purple because it has to mean ONE thing across the window and not collide
        /// with anything already spoken for: amber and cyan are the two buses, yellow
        /// is detect-arming, red is on-air, and the accent is a driven parameter.
        /// Purple was the colour left that reads at a glance.
        /// NEON rather than lavender. The first purple was desaturated enough to read
        /// as grey-violet against a dark panel — a colour that says "disabled" before
        /// it says "driving itself". Pushing the blue to full and dropping the green
        /// takes it to the magenta end, where it glows instead of sitting.
        static let sweepMark = NSColor(srgbRed: 0xc0 / 255.0, green: 0x3c / 255.0, blue: 0xff / 255.0, alpha: 0.9)

        /// The same purple for the arming outline, which pulses rather than sits.
        ///
        /// Brighter still, because an outline is a thin line and a thin line loses more
        /// apparent saturation than a filled bar does.
        static let sweepArming = NSColor(srgbRed: 0xd0 / 255.0, green: 0x5a / 255.0, blue: 0xff / 255.0, alpha: 1)

        /// What a FOCUS control turns when it is the one receiving your next action.
        ///
        /// Louder than the plain bus tint: focus is a state you need to read across
        /// the room mid-set, and the tint alone was doing the same job as every other
        /// amber thing in the window.
        static let focusOn = NSColor(srgbRed: 0xff / 255.0, green: 0x9a / 255.0, blue: 0x1f / 255.0, alpha: 1)

        /// The bus tint a channel belongs to. A, B are bus one; C, D are bus two —
        /// the same amber and cyan this window uses everywhere else to say which
        /// half of the desk you are looking at.
        static func busTint(forChannel channel: String) -> NSColor {
            ["C", "D"].contains(channel.uppercased()) ? busTwo : busOne
        }

        static let tallyOnAir = NSColor(srgbRed: 0.85, green: 0.13, blue: 0.13, alpha: 1)
        /// An unlit key: dark, but clearly a key rather than a hole.
        static let busButtonUnlit = NSColor(white: 0.22, alpha: 1)

        /// The transport cluster's recessed readout — darker than the toolbar, so it
        /// reads as an inset instrument panel rather than another button.
        static let displayBackground = NSColor(srgbRed: 0.07, green: 0.075, blue: 0.08, alpha: 1)
        static let displayBorder = NSColor(white: 1.0, alpha: 0.12)
        static let displayText = NSColor(srgbRed: 0.85, green: 0.92, blue: 1.0, alpha: 1)
        static let displayDimText = NSColor(srgbRed: 0.85, green: 0.92, blue: 1.0, alpha: 0.45)
        static let displayHighlight = NSColor(white: 1.0, alpha: 0.10)

        /// The launch screen's backdrop — darker than the window, so it reads as
        /// something in front of the app rather than part of it.
        static let launchBackground = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)

        /// Fill behind a video preview that has no source yet.
        static let previewEmpty = NSColor(white: 0.07, alpha: 1)

        /// The fader's unfilled slot.
        static let faderTrack = NSColor(white: 0, alpha: 0.45)
        /// The fader's cap. Near-white so it stands off the track at any fill level.
        static let faderCap = NSColor(white: 0.90, alpha: 1)
        /// The line down the middle of the cap.
        static let faderCapLine = NSColor(white: 0.45, alpha: 1)

        /// Hairline drawn where two panels in the same group meet.
        static let groupSeam = NSColor(white: 1.0, alpha: 0.07)

        /// The record button, idle, hovered, running, and unavailable.
        static let recordIdle = NSColor(srgbRed: 0.85, green: 0.16, blue: 0.16, alpha: 1)
        static let recordHover = NSColor(srgbRed: 1.0, green: 0.25, blue: 0.25, alpha: 1)
        static let recordActive = NSColor(srgbRed: 1.0, green: 0.19, blue: 0.19, alpha: 1)
        static let recordDisabled = NSColor(white: 0.4, alpha: 1)
        static let recordRing = NSColor(white: 1.0, alpha: 0.28)
        /// An unarmed per-preview dot.
        static let recordDisarmed = NSColor(white: 1.0, alpha: 0.22)

        /// The beat pulse painted on the window chrome.
        ///
        /// Deliberately faint. The point is to feel the tempo in peripheral vision
        /// while watching the picture — anything strong enough to notice directly
        /// would compete with the thing you are actually looking at.
        /// The beat pulse darkens the canvas toward black rather than lifting it
        /// toward a colour. A dark room gets brighter when something flashes at you,
        /// which pulls the eye off the picture — the whole point of this is to be felt
        /// at the edge of vision, and a dip does that without competing.
        /// The resting playhead line on a source preview. Grey, low contrast: it is
        /// a readout you glance at, not a control competing with the picture.
        static let miniPlayBarTrack = NSColor.white.withAlphaComponent(0.22)
        static let miniPlayBarFill = NSColor.white.withAlphaComponent(0.75)

        /// Behind the shuttle where it floats over a source's picture. Dark and
        /// mostly opaque: the keys sit on arbitrary video, and a transport you can
        /// only read against dark footage is one you cannot trust in a set.
        static let shuttleScrim = NSColor.black.withAlphaComponent(0.62)

        static let beatPulse = NSColor.black
        /// The stronger flash when the tempo itself changes.
        static let tempoChangeFlash = NSColor(srgbRed: 0.30, green: 0.70, blue: 1.0, alpha: 1)
    }

    // MARK: - Type

    enum Font {
        /// Panel titles.
        static let panelTitle = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// Small labels next to controls.
        static let label = NSFont.systemFont(ofSize: 11, weight: .regular)
        /// Even smaller labels (mapping badges, param codes).
        static let tinyLabel = NSFont.systemFont(ofSize: 10, weight: .regular)
        /// Monospaced readouts: param codes, negotiated modes, fps.
        static let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        /// The large tempo readout in the toolbar.
        static let tempo = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        /// The letter on a bus button. Big, because that is the whole point of it.
        static let busButton = NSFont.systemFont(ofSize: 17, weight: .bold)

        /// The camcorder on-screen-display face, for the transport readout.
        ///
        /// Segmented and slightly crude, the way a viewfinder overlay is. It belongs
        /// on the numbers you glance at mid-take and nowhere else — used everywhere
        /// it would be a costume rather than a voice.
        ///
        /// Not bundled: it is whatever the machine has. If it is missing, a
        /// monospaced-digit system font stands in, which keeps the digits from
        /// jittering as they change even though it loses the character.
        static func osd(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont(name: "VCR OSD Mono", size: size)
                ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }

        /// True when the OSD face is actually available, so the self-QA can say which
        /// of the two it rendered.
        static var hasOSDFace: Bool { NSFont(name: "VCR OSD Mono", size: 12) != nil }
    }

    /// The resting playhead line on a source preview (`VBMiniPlayBar`).
    enum MiniPlayBar {
        /// Height of the view, which is mostly the hit-free margin around the line.
        static let height: CGFloat = 10
        /// Thickness of the drawn line itself — AVKit's resting scrubber is about
        /// this, and thinner reads as an artefact rather than a control.
        static let thickness: CGFloat = 3

        /// How far above a preview's bottom edge its floating controls sit.
        ///
        /// A preview already draws its own caption bottom-left and its routing button
        /// bottom-right. Anything overlaid at the bottom lands on top of both — and
        /// the routing button is CLICKABLE, so the hover transport covering it made
        /// it unreachable precisely when the pointer was there to press it. This is
        /// the height of that strip plus a little air.
        static let bottomClearance: CGFloat = 20

        /// Gap between the play bar and the shuttle floating above it.
        static let shuttleGap: CGFloat = 6
    }

    /// Marks the FOCUSED item on any "which one receives what I do next" control —
    /// the library's load focus, an FX card's channel selector. One glyph, used in
    /// both places, so the two read as the same kind of switch rather than as two
    /// unrelated toggles that happen to list channels.
    static let focusCaret = "\u{25B8}"
}
