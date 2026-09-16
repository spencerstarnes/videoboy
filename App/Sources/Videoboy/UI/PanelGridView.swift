//
//  PanelGridView.swift — the 5x5 panel grid (SPEC 14.1, normative).
//
//  Purpose : Places every panel in the fixed arrangement from
//            docs/mockups/layout-v6.html. Panels collapse but never move, so this
//            file owns positions and nothing else does.
//  Inputs  : the panels it constructs; the view's own width, which selects a breakpoint.
//  Outputs : laid-out subviews.
//  Connects: PanelView (each cell), Theme (weights, gutters, breakpoints), and the
//            panel body views under UI/Panels/.
//  Extend  : to add a panel you must change the mockup first — the arrangement is
//            normative. Panel *contents* are extended in their own body views.
//
//  Why manual layout rather than nested NSSplitViews: the grid has row and column
//  spans (the previews span two rows, the FX columns span three, the settings bar
//  spans three columns). Expressing spans through nested splits needs a tree that no
//  longer resembles the layout it produces, and dividers that must then be pinned to
//  stop the user dragging them. Computing five column edges and five row edges from
//  the weight tables is shorter, reads like the CSS grid it mirrors, and is trivial
//  to repair. SPEC 1.5: prefer the boring, obvious, repairable version.
//

import AppKit
import VideoboyCore

/// Where a panel sits in the grid, in cells.
struct GridPlacement {
    let column: Int
    let row: Int
    let columnSpan: Int
    let rowSpan: Int

    init(column: Int, row: Int, columnSpan: Int = 1, rowSpan: Int = 1) {
        self.column = column
        self.row = row
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }
}

/// How much of the layout is shown, chosen by window width (SPEC 14.4).
enum LayoutBreakpoint {
    /// Everything: five columns.
    case wide
    /// Outer source/FX columns shrink to rails and their panels collapse.
    case compact
    /// Outer columns hidden entirely; program, faders and settings bar remain.
    case narrow

    static func forWidth(_ width: CGFloat) -> LayoutBreakpoint {
        if width >= Theme.Breakpoint.wide { return .wide }
        if width >= Theme.Breakpoint.compact { return .compact }
        return .narrow
    }
}

/// The grid itself.
final class PanelGridView: NSView {

    /// A panel plus its placement.
    private struct PlacedPanel {
        let panel: PanelView
        let placement: GridPlacement
        /// True for the outer source and FX columns, which respond to breakpoints.
        let isOuterColumn: Bool
    }

    private var placedPanels: [PlacedPanel] = []
    private var currentBreakpoint: LayoutBreakpoint = .wide

    /// Panels other parts of the app need to reach. Built once, kept for wiring.
    let panels = PanelSet()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.content.cgColor
        placePanels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelGridView is created in code, never from a nib")
    }

    override var isFlipped: Bool { true }

    // MARK: - Panel construction

    /// Builds all sixteen panels in the arrangement of SPEC 14.1.
    ///
    /// The placements below are the mockup's `grid-template-areas`, transcribed:
    ///
    ///     "srcA one  prog two  srcC"
    ///     "srcB one  prog two  srcD"
    ///     "fxL  fdA  fdP  fdC  fxR"
    ///     "fxL  libA brow libC fxR"
    ///     "fxL  set  set  set  fxR"
    ///
    private func placePanels() {
        let set = panels

        func place(_ panel: PanelView, _ placement: GridPlacement, outer: Bool = false) {
            panel.translatesAutoresizingMaskIntoConstraints = true
            addSubview(panel)
            placedPanels.append(PlacedPanel(panel: panel, placement: placement, isOuterColumn: outer))
        }

        // Row 0-1, outer columns: the four source panels.
        place(set.sourceA, GridPlacement(column: 0, row: 0), outer: true)
        place(set.sourceB, GridPlacement(column: 0, row: 1), outer: true)
        place(set.sourceC, GridPlacement(column: 4, row: 0), outer: true)
        place(set.sourceD, GridPlacement(column: 4, row: 1), outer: true)

        // Row 0-1, inner columns: the three previews, each spanning two rows.
        place(set.subMixOne, GridPlacement(column: 1, row: 0, rowSpan: 2))
        place(set.program, GridPlacement(column: 2, row: 0, rowSpan: 2))
        place(set.subMixTwo, GridPlacement(column: 3, row: 0, rowSpan: 2))

        // Row 2: the three faders.
        place(set.faderAB, GridPlacement(column: 1, row: 2))
        place(set.faderOneTwo, GridPlacement(column: 2, row: 2))
        place(set.faderCD, GridPlacement(column: 3, row: 2))

        // Rows 2-4, outer columns: the two tall FX chains.
        place(set.effectsOne, GridPlacement(column: 0, row: 2, rowSpan: 3), outer: true)
        place(set.effectsTwo, GridPlacement(column: 4, row: 2, rowSpan: 3), outer: true)

        // Row 3: the two libraries and the central asset browser.
        place(set.libraryOne, GridPlacement(column: 1, row: 3))
        place(set.assetBrowser, GridPlacement(column: 2, row: 3))
        place(set.libraryTwo, GridPlacement(column: 3, row: 3))

        // Row 4: the settings bar, spanning the three inner columns.
        place(set.settingsBar, GridPlacement(column: 1, row: 4, columnSpan: 3))

        Log.info(.app, "panel grid built with \(placedPanels.count) panels")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let breakpoint = LayoutBreakpoint.forWidth(bounds.width)
        if breakpoint != currentBreakpoint {
            currentBreakpoint = breakpoint
            applyBreakpoint(breakpoint)
        }

        let padding = Theme.Metrics.gridPadding
        let gutter = Theme.Metrics.panelGutter
        let contentWidth = bounds.width - padding * 2
        let contentHeight = bounds.height - padding * 2
        guard contentWidth > 0, contentHeight > 0 else { return }

        let columnEdges = edges(
            weights: columnWeights(for: breakpoint),
            total: contentWidth, gutter: gutter, origin: padding
        )
        let rowEdges = edges(
            weights: Theme.Grid.rowWeights,
            total: contentHeight, gutter: gutter, origin: padding
        )

        for placed in placedPanels {
            let placement = placed.placement
            // Hidden panels still occupy their cell in the tables above; they are
            // simply not drawn, so the remaining columns keep their proportions.
            guard !placed.panel.isHidden else { continue }

            let left = columnEdges[placement.column].start
            let lastColumn = min(placement.column + placement.columnSpan - 1, columnEdges.count - 1)
            let right = columnEdges[lastColumn].end

            let top = rowEdges[placement.row].start
            let lastRow = min(placement.row + placement.rowSpan - 1, rowEdges.count - 1)
            let bottom = rowEdges[lastRow].end

            placed.panel.frame = NSRect(
                x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0)
            )
        }
    }

    /// Column weights for a breakpoint. The outer columns narrow, then vanish.
    private func columnWeights(for breakpoint: LayoutBreakpoint) -> [CGFloat] {
        var weights = Theme.Grid.columnWeights
        switch breakpoint {
        case .wide:
            break
        case .compact:
            // Outer columns become rails: wide enough for a collapsed panel header.
            weights[0] = 0.35
            weights[4] = 0.35
        case .narrow:
            // Zero-weight columns still exist in the table so the remaining
            // placements keep their indices; they simply take no space.
            weights[0] = 0
            weights[4] = 0
        }
        return weights
    }

    /// Converts weights into start/end pixel edges, accounting for gutters.
    ///
    /// Zero-weight tracks get no space and no gutter, which is how the narrow
    /// breakpoint removes the outer columns cleanly.
    private func edges(
        weights: [CGFloat], total: CGFloat, gutter: CGFloat, origin: CGFloat
    ) -> [(start: CGFloat, end: CGFloat)] {
        let visibleCount = weights.filter { $0 > 0 }.count
        let gutterTotal = gutter * CGFloat(max(visibleCount - 1, 0))
        let available = max(total - gutterTotal, 0)
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else {
            return weights.map { _ in (origin, origin) }
        }

        var result: [(start: CGFloat, end: CGFloat)] = []
        var cursor = origin
        for weight in weights {
            let size = available * weight / weightSum
            result.append((start: cursor, end: cursor + size))
            // Only a track that took space is followed by a gutter.
            if weight > 0 { cursor += size + gutter }
        }
        return result
    }

    /// Collapses or hides the outer columns for a breakpoint.
    private func applyBreakpoint(_ breakpoint: LayoutBreakpoint) {
        Log.info(.app, "layout breakpoint: \(breakpoint)")
        for placed in placedPanels where placed.isOuterColumn {
            switch breakpoint {
            case .wide:
                placed.panel.isHidden = false
                placed.panel.setCollapsed(false)
            case .compact:
                placed.panel.isHidden = false
                placed.panel.setCollapsed(true)
            case .narrow:
                placed.panel.isHidden = true
            }
        }
    }
}
