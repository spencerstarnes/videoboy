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

/// The four groups that can be collapsed to the edge of the window (Resolve-style).
///
/// Collapsing is by GROUP, not by panel: the things that fold away together are the
/// things you stop needing together. Fold both groups on one side and that whole
/// column shrinks to a rail, handing its width to the monitors and the library —
/// which is the point of collapsing anything.
enum PanelGroup: String, CaseIterable {
    case sourcesLeft
    case effectsLeft
    case effectsRight
    case sourcesRight

    /// Name shown on the rail and in the toolbar's show/hide control.
    var displayName: String {
        switch self {
        case .sourcesLeft: "A/B"
        case .effectsLeft: "FX 1"
        case .effectsRight: "FX 2"
        case .sourcesRight: "C/D"
        }
    }

    /// Full name for the rail's rotated label and the tooltip.
    var longName: String {
        switch self {
        case .sourcesLeft: "Sources A/B"
        case .effectsLeft: "A/B FX"
        case .effectsRight: "C/D FX"
        case .sourcesRight: "Sources C/D"
        }
    }

    /// Which grid column this group occupies.
    var column: Int {
        switch self {
        case .sourcesLeft, .effectsLeft: 0
        case .sourcesRight, .effectsRight: 4
        }
    }

    /// True for the groups on the left-hand edge.
    var isLeadingEdge: Bool { column == 0 }

    /// Which rows of its column this group occupies.
    var rows: ClosedRange<Int> {
        switch self {
        case .sourcesLeft, .sourcesRight: 0...1
        case .effectsLeft, .effectsRight: 2...4
        }
    }

    /// The other group sharing this group's column.
    var sibling: PanelGroup {
        switch self {
        case .sourcesLeft: .effectsLeft
        case .effectsLeft: .sourcesLeft
        case .sourcesRight: .effectsRight
        case .effectsRight: .sourcesRight
        }
    }
}

/// The two horizontal bands an outer column is divided into.
///
/// The outer columns hold two different things stacked — sources above, an effect
/// chain below — and collapsing one of them should hand its cells to the other. Which
/// neighbour takes them differs by band, so the two bands get their own column widths
/// rather than the grid having one set for the whole window.
enum RowBand {
    /// Rows 0-1: the sources and the previews.
    case sources
    /// Rows 2-4: the effect chains, faders, libraries and settings bar.
    case effects

    static func containing(row: Int) -> RowBand { row <= 1 ? .sources : .effects }
}

/// Which edges of a panel are butted against a neighbour.
///
/// Panels that are always shown together — A above B, C above D — are joined rather
/// than floated apart. This is the Resolve/FCP reading of space: a gap means "these
/// are separate concerns", so putting one everywhere makes the gaps meaningless and
/// the window busier than it needs to be.
struct GroupEdge: OptionSet {
    let rawValue: Int
    static let top = GroupEdge(rawValue: 1 << 0)
    static let bottom = GroupEdge(rawValue: 1 << 1)
    static let leading = GroupEdge(rawValue: 1 << 2)
    static let trailing = GroupEdge(rawValue: 1 << 3)
}

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
        /// Edges butted against a neighbour, which take no gutter.
        let joined: GroupEdge
        /// The collapsible group this panel belongs to, if any.
        let group: PanelGroup?
    }

    private var placedPanels: [PlacedPanel] = []
    private var currentBreakpoint: LayoutBreakpoint = .wide

    /// Groups the user has folded away.
    private(set) var collapsedGroups: Set<PanelGroup> = []

    /// The rail standing in for each collapsed group.
    private var rails: [PanelGroup: CollapsedRailView] = [:]

    /// Called when a group is collapsed or restored, so the toolbar can keep up.
    var onGroupCollapseChanged: ((PanelGroup, Bool) -> Void)?

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

    /// Takes the chrome tint from the shell, so the gaps between panels carry the
    /// pulse too. The panels themselves are left alone — only the space around them
    /// breathes.
    func setChromeTint(_ colour: NSColor) {
        layer?.backgroundColor = colour.cgColor
    }

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

        func place(
            _ panel: PanelView, _ placement: GridPlacement,
            outer: Bool = false, joined: GroupEdge = [], group: PanelGroup? = nil
        ) {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.squaredEdges = joined
            addSubview(panel)
            placedPanels.append(PlacedPanel(
                panel: panel, placement: placement, isOuterColumn: outer,
                joined: joined, group: group))
        }

        // Row 0-1, outer columns: the four source panels. A sits directly on B and
        // C on D — they feed the same bus and are never used apart, so they are one
        // block with a hairline between rather than two floating boxes.
        place(set.sourceA, GridPlacement(column: 0, row: 0), outer: true, joined: .bottom,
              group: .sourcesLeft)
        place(set.sourceB, GridPlacement(column: 0, row: 1), outer: true, joined: .top,
              group: .sourcesLeft)
        place(set.sourceC, GridPlacement(column: 4, row: 0), outer: true, joined: .bottom,
              group: .sourcesRight)
        place(set.sourceD, GridPlacement(column: 4, row: 1), outer: true, joined: .top,
              group: .sourcesRight)

        // Row 0-1, inner columns: the three previews, each spanning two rows.
        place(set.subMixOne, GridPlacement(column: 1, row: 0, rowSpan: 2))
        place(set.program, GridPlacement(column: 2, row: 0, rowSpan: 2))
        place(set.subMixTwo, GridPlacement(column: 3, row: 0, rowSpan: 2))

        // Row 2: the three faders.
        place(set.faderAB, GridPlacement(column: 1, row: 2))
        place(set.faderOneTwo, GridPlacement(column: 2, row: 2))
        place(set.faderCD, GridPlacement(column: 3, row: 2))

        // Rows 2-4, outer columns: the two tall FX chains.
        place(set.effectsOne, GridPlacement(column: 0, row: 2, rowSpan: 3), outer: true,
              group: .effectsLeft)
        place(set.effectsTwo, GridPlacement(column: 4, row: 2, rowSpan: 3), outer: true,
              group: .effectsRight)

        // Row 3: the two libraries and the central asset browser. The settings bar
        // sits directly beneath them, so those edges join too.
        place(set.libraryOne, GridPlacement(column: 1, row: 3), joined: .bottom)
        place(set.assetBrowser, GridPlacement(column: 2, row: 3), joined: .bottom)
        place(set.libraryTwo, GridPlacement(column: 3, row: 3), joined: .bottom)

        // Row 4: the settings bar, spanning the three inner columns.
        place(set.settingsBar, GridPlacement(column: 1, row: 4, columnSpan: 3), joined: .top)

        // One rail per group, hidden until its group is folded away.
        for group in PanelGroup.allCases {
            let rail = CollapsedRailView(title: group.longName, isLeadingEdge: group.isLeadingEdge)
            rail.translatesAutoresizingMaskIntoConstraints = true
            rail.isHidden = true
            rail.target = self
            rail.action = #selector(railClicked(_:))
            rail.identifier = NSUserInterfaceItemIdentifier(group.rawValue)
            addSubview(rail)
            rails[group] = rail
        }

        // Clicking a panel's title and clicking its group's button in the toolbar are
        // the same act. Panels with no group have nowhere to give their space to, so
        // their headers say nothing rather than collapsing into a hole the grid still
        // reserves — which is what "it hides the window but does not collapse it"
        // looked like.
        for placed in placedPanels {
            if let group = placed.group {
                placed.panel.onHeaderClicked = { [weak self] in
                    guard let self else { return }
                    self.setGroup(group, collapsed: !self.isCollapsed(group))
                }
            } else {
                placed.panel.makeHeaderInert()
            }
        }

        Log.info(.app, "panel grid built with \(placedPanels.count) panels")
    }

    // MARK: - Collapsing

    /// Folds a group away to the edge, or brings it back.
    func setGroup(_ group: PanelGroup, collapsed: Bool) {
        if collapsed { collapsedGroups.insert(group) } else { collapsedGroups.remove(group) }
        for placed in placedPanels where placed.group == group {
            placed.panel.isHidden = collapsed
            placed.panel.setGroupCollapsed(collapsed)
        }
        rails[group]?.isHidden = !collapsed
        needsLayout = true
        Log.info(.app, "\(group.longName) \(collapsed ? "collapsed" : "restored")")
        onGroupCollapseChanged?(group, collapsed)
    }

    /// What each panel's header does, for the audit.
    ///
    /// Three legitimate answers and no fourth: it collapses a group, it is inert, or
    /// it is a bug. The failure being guarded against is a header that hides its
    /// panel while the grid keeps reserving the cell.
    enum HeaderBehaviour: Equatable {
        case collapsesGroup(PanelGroup)
        case inert
        case hidesItselfLeavingAHole
    }

    /// Every panel's title and what clicking it does.
    func headerBehaviours() -> [(title: String, behaviour: HeaderBehaviour)] {
        placedPanels.map { placed in
            if let group = placed.group {
                return (placed.panel.title, .collapsesGroup(group))
            }
            return (
                placed.panel.title,
                placed.panel.isHeaderInert ? .inert : .hidesItselfLeavingAHole
            )
        }
    }

    /// True when a group is folded away.
    func isCollapsed(_ group: PanelGroup) -> Bool { collapsedGroups.contains(group) }

    @objc private func railClicked(_ sender: CollapsedRailView) {
        guard let raw = sender.identifier?.rawValue, let group = PanelGroup(rawValue: raw) else { return }
        setGroup(group, collapsed: false)
    }

    /// The groups sharing a column with this one.
    private func groups(inColumn column: Int) -> [PanelGroup] {
        PanelGroup.allCases.filter { $0.column == column }
    }

    /// True when every group in a column is folded away, so the column itself can
    /// shrink to a rail and hand its width to the middle of the window.
    private func columnIsFullyCollapsed(_ column: Int) -> Bool {
        let inColumn = groups(inColumn: column)
        return !inColumn.isEmpty && inColumn.allSatisfy(collapsedGroups.contains)
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

        // One set of column edges per band. With nothing collapsed the two are
        // identical and the window looks like a plain grid; they diverge only when a
        // group folds away and its cells are handed to a neighbour.
        let bandEdges: [RowBand: [(start: CGFloat, end: CGFloat)]] = [
            .sources: edges(
                weights: columnWeights(for: breakpoint, band: .sources),
                total: contentWidth, gutter: gutter, origin: padding),
            .effects: edges(
                weights: columnWeights(for: breakpoint, band: .effects),
                total: contentWidth, gutter: gutter, origin: padding)
        ]
        // The preview row band is sized from the COLUMN WIDTH so those panels come
        // out 4:3, and the rows below share whatever is left. Deriving it the other
        // way — fixed row weights and a letterboxed picture inside — left a band of
        // dead panel above and below every preview.
        //
        // If the window is too short to give the previews their full height, they
        // take what there is rather than pushing the rest of the grid off the bottom:
        // a squashed preview is recoverable, a settings bar you cannot reach is not.
        let previewColumnWidth = bandEdges[.sources].map { edges -> CGFloat in
            let centre = edges[2]
            return max(centre.end - centre.start, 0)
        } ?? 0
        let rowEdges = previewAwareRowEdges(
            previewColumnWidth: previewColumnWidth,
            total: contentHeight, gutter: gutter, origin: padding
        )

        // Rails occupy their group's cells while it is folded away — except when the
        // sibling has taken those cells over, in which case the rail becomes a thin
        // strip along the top. The group still has to be restorable; it just must not
        // cost a column of width to say so.
        for (group, rail) in rails where !rail.isHidden {
            let band = RowBand.containing(row: group.rows.lowerBound)
            let columnEdges = bandEdges[band] ?? bandEdges[.effects]!
            let left = columnEdges[group.column].start
            let right = columnEdges[group.column].end
            let top = rowEdges[group.rows.lowerBound].start
            let bottom = rowEdges[min(group.rows.upperBound, rowEdges.count - 1)].end

            if siblingHasTakenOver(group) {
                rail.isHorizontal = true
                rail.frame = NSRect(
                    x: left, y: top,
                    width: max(right - left, 0), height: Theme.Grid.railStripHeight)
            } else {
                rail.isHorizontal = false
                rail.frame = NSRect(
                    x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
            }
        }

        for placed in placedPanels {
            let placement = placed.placement
            // Hidden panels still occupy their cell in the tables above; they are
            // simply not drawn, so the remaining columns keep their proportions.
            guard !placed.panel.isHidden else { continue }

            let columnEdges = bandEdges[RowBand.containing(row: placement.row)]!
            let left = columnEdges[placement.column].start
            let lastColumn = min(placement.column + placement.columnSpan - 1, columnEdges.count - 1)
            let right = columnEdges[lastColumn].end

            // A group whose sibling has folded away grows into the vacated rows,
            // leaving room for the strip that brings the sibling back.
            var firstRow = placement.row
            var topInset: CGFloat = 0
            if let group = placed.group, siblingHasTakenOver(group.sibling) {
                firstRow = min(firstRow, group.sibling.rows.lowerBound)
                topInset = Theme.Grid.railStripHeight + gutter / 2
            }

            let top = rowEdges[firstRow].start + topInset
            let lastRow = min(placement.row + placement.rowSpan - 1, rowEdges.count - 1)
            let bottom = rowEdges[lastRow].end

            // A joined edge reclaims its half of the gutter, so the two panels meet.
            let halfGutter = gutter / 2
            var frame = NSRect(
                x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0)
            )
            if placed.joined.contains(.bottom) { frame.size.height += halfGutter + 0.5 }
            if placed.joined.contains(.top) {
                frame.origin.y -= halfGutter + 0.5
                frame.size.height += halfGutter + 0.5
            }
            if placed.joined.contains(.trailing) { frame.size.width += halfGutter + 0.5 }
            if placed.joined.contains(.leading) {
                frame.origin.x -= halfGutter + 0.5
                frame.size.width += halfGutter + 0.5
            }
            placed.panel.frame = frame
        }
    }

    /// True when this group is collapsed and its sibling has spread over its cells.
    ///
    /// Only the sources band is given away this way. Folding the sources leaves the
    /// effect chain wanting height, which is what a long chain is short of; folding
    /// the chain leaves the libraries and the browser wanting width, which they get
    /// from the column narrowing instead. The two halves of the column want opposite
    /// things, so they are not treated the same.
    private func siblingHasTakenOver(_ group: PanelGroup) -> Bool {
        collapsedGroups.contains(group)
            && !collapsedGroups.contains(group.sibling)
            && group.rows.lowerBound == 0
    }

    /// Column weights for a breakpoint and band, after collapsing is accounted for.
    private func columnWeights(for breakpoint: LayoutBreakpoint, band: RowBand) -> [CGFloat] {
        var weights = Theme.Grid.columnWeights
        switch breakpoint {
        case .wide:
            break
        case .compact:
            // Outer columns become rails: wide enough for a collapsed panel header.
            weights[0] = Theme.Grid.railWeight
            weights[4] = Theme.Grid.railWeight
        case .narrow:
            // Zero-weight columns still exist in the table so the remaining
            // placements keep their indices; they simply take no space.
            weights[0] = 0
            weights[4] = 0
        }

        // A column whose groups are ALL folded away shrinks to a rail in both bands,
        // whatever the breakpoint. This is what makes collapsing worth doing: the
        // width goes to the monitors and the library rather than being left empty.
        for column in [0, 4] where columnIsFullyCollapsed(column) && weights[column] > 0 {
            weights[column] = Theme.Grid.railWeight
            continue
        }

        // Otherwise a band narrows only if the group occupying THAT band is folded
        // away and its sibling has not taken the cells over. Folding the effect chain
        // is the case this serves: the libraries, browser and settings bar widen into
        // the space, while the sources above keep their full column.
        for column in [0, 4] where weights[column] > Theme.Grid.railWeight {
            guard let group = groups(inColumn: column).first(where: {
                RowBand.containing(row: $0.rows.lowerBound) == band
            }) else { continue }
            if collapsedGroups.contains(group) && !siblingHasTakenOver(group) {
                weights[column] = Theme.Grid.railWeight
            }
        }
        return weights
    }

    /// Row edges with the preview band sized to make those panels 4:3.
    ///
    /// Rows 0 and 1 are the preview band — each preview spans both — so together they
    /// must be three quarters of the preview column's width. The remaining rows keep
    /// their weights relative to each other and divide what is left.
    private func previewAwareRowEdges(
        previewColumnWidth: CGFloat, total: CGFloat, gutter: CGFloat, origin: CGFloat
    ) -> [(start: CGFloat, end: CGFloat)] {
        let weights = Theme.Grid.rowWeights
        let gutterTotal = gutter * CGFloat(max(weights.filter { $0 > 0 }.count - 1, 0))
        let available = max(total - gutterTotal, 0)

        // The output bar is a FIXED height, taken off the top before anything else
        // shares out what is left.
        //
        // It was a weight like every other row, which meant it grew in proportion to
        // the window — and it holds one strip of 22pt controls that cannot use the
        // height, so every extra pixel went into empty space inside the panel. That
        // is the whole reason it kept looking chunky no matter how much the weight
        // was trimmed: a proportion of a bigger window is a bigger bar.
        let outputBar = min(Theme.Grid.outputBarHeight, available)
        let availableAboveBar = max(available - outputBar, 0)

        // What the previews want, and what the rest of the grid must keep.
        // The 4:3 height is a FLOOR now, not a ceiling. Capping the band at exactly
        // 4:3 of one column's width meant the source monitors could not grow however
        // much room the window had — they were small by arithmetic rather than by
        // layout. Whichever of the two is larger wins, and the lower rows keep their
        // minimum either way.
        let wanted = previewColumnWidth / Theme.Metrics.previewAspectRatio
        let share = availableAboveBar * Theme.Grid.previewBandShare
        let lowerWeights = Array(weights.dropFirst(2).dropLast())
        let lowerMinimum = Theme.Grid.minimumLowerRowsHeight
        let previewBand = min(max(wanted, share), max(availableAboveBar - lowerMinimum, 0))

        // The band is split between rows 0 and 1 in their existing proportion, so a
        // source panel above another keeps the relationship it had.
        let upperSum = weights[0] + weights[1]
        let row0 = upperSum > 0 ? previewBand * weights[0] / upperSum : previewBand / 2
        let row1 = previewBand - row0

        let lowerAvailable = max(availableAboveBar - previewBand, 0)
        let lowerSum = lowerWeights.reduce(0, +)
        let heights = [row0, row1] + lowerWeights.map { weight -> CGFloat in
            lowerSum > 0 ? lowerAvailable * weight / lowerSum : 0
        } + [outputBar]

        var result: [(start: CGFloat, end: CGFloat)] = []
        var cursor = origin
        for (index, height) in heights.enumerated() {
            result.append((start: cursor, end: cursor + height))
            if weights[index] > 0 { cursor += height + gutter }
        }
        return result
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
