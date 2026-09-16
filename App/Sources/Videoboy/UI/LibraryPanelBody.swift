//
//  LibraryPanelBody.swift — the two sub-mix libraries and the central asset browser.
//
//  Purpose : SPEC 14.2's thumbnail grids. The sub-mix libraries hold the working set
//            staged for one side; the asset browser is the global, tabbed library.
//            Both use `NSCollectionView` as SPEC 14.3 requires.
//  Inputs  : `LibraryItem`s (name plus a type badge).
//  Outputs : a scrolling grid of labelled thumbnails.
//  Connects: Controls, Theme; later, the samples manifest and the render graph.
//  Extend  : drag-to-load and real thumbnails arrive with the source modules. The
//            grid itself should not need changing.
//

import AppKit
import VideoboyCore

/// One entry in a library grid.
struct LibraryItem {
    /// Display name, e.g. "bars.dv".
    let name: String
    /// Short type badge: DV, MOV, MPG, GEN, SVG, SCR, IP, CAP, EMU, IMG.
    let badge: String
    /// False for item kinds whose source module is not built yet.
    let isAvailable: Bool
}

/// The view for one library item: a fixed-size thumbnail with a badge and a caption.
///
/// Every item is exactly the same size. Items that size themselves to their caption
/// read as clutter however neatly they are spaced, and a grid whose cells differ is
/// not really a grid.
final class LibraryItemView: NSView {

    init(item: LibraryItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let thumbnail = NSView()
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = Theme.Color.previewEmpty.cgColor
        thumbnail.layer?.cornerRadius = 2
        thumbnail.layer?.borderWidth = Theme.Metrics.hairline
        thumbnail.layer?.borderColor = Theme.Color.panelBorder.cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        let badge = Controls.monoLabel(
            item.badge,
            color: item.isAvailable ? Theme.Color.accent : Theme.Color.textTertiary
        )
        badge.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.addSubview(badge)

        let caption = Controls.label(
            item.name, font: Theme.Font.tinyLabel,
            color: item.isAvailable ? Theme.Color.textSecondary : Theme.Color.textTertiary
        )
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.lineBreakMode = .byTruncatingMiddle
        caption.alignment = .center
        // The caption must never widen the cell — a long filename truncates instead.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(thumbnail)
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailSide),

            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailImageHeight),

            badge.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 2),
            badge.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 3),

            caption.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.heightAnchor.constraint(equalToConstant: Theme.Metrics.thumbnailCaptionHeight),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}

/// Which kind of asset a browser tab shows.
enum AssetTab: String, CaseIterable {
    case sources
    case generators
    case graphics
    case clips
    case images

    var displayName: String {
        switch self {
        case .sources: "Sources"
        case .generators: "Generators"
        case .graphics: "Graphics"
        case .clips: "Clips"
        case .images: "Images"
        }
    }

    /// What to say when a tab has nothing in it, so an empty grid is never just a
    /// blank rectangle the user has to guess about.
    var emptyMessage: String {
        switch self {
        case .sources: "No media in samples/. Drop files there and re-run scripts/make-fixtures.sh."
        case .generators: "No generators available."
        case .graphics: "SVG and vector sources are not built yet (SPEC §17)."
        case .clips: "Clip bins are not built yet."
        case .images: "Still-image sources are not built yet."
        }
    }
}

/// A library grid with a toolbar above it.
final class LibraryPanelBody: NSView {

    private let grid = NSGridView()

    /// Grids by tab, so switching a tab swaps content rather than rebuilding it.
    private var gridsByTab: [AssetTab: NSView] = [:]
    private var emptyLabelsByTab: [AssetTab: NSTextField] = [:]
    private var currentTab: AssetTab = .sources
    private let columns: Int

    /// Called when an item is chosen. Nil until the app wires it.
    var onItemChosen: ((LibraryItem) -> Void)?

    /// - Parameters:
    ///   - items: what the Sources tab shows.
    ///   - columns: 3 for the sub-mix libraries, 6 for the central browser.
    ///   - showsTabs: true for the asset browser, which is tabbed by asset kind.
    init(items: [LibraryItem], columns: Int, showsTabs: Bool) {
        self.columns = columns
        super.init(frame: .zero)

        var header: [NSView] = []
        var tabControl: NSSegmentedControl?
        if showsTabs {
            let tabs = Controls.segmented(
                AssetTab.allCases.map(\.displayName), selected: 0,
                target: self, action: #selector(tabChanged(_:)))
            tabControl = tabs
            header.append(tabs)
        } else {
            header.append(Controls.popUp(["Page 1"], enabled: false))
        }
        let search = Controls.searchField(
            placeholder: showsTabs ? "Search library…" : "Search…", enabled: showsTabs)
        search.target = self
        search.action = #selector(searchChanged(_:))
        header.append(search)
        if showsTabs {
            header.append(Controls.button("Import…", enabled: false))
        }
        let headerRow = Controls.row(header, spacing: 4)
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)

        // A flipped document view keeps the grid anchored to the top of the panel.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Build every tab's grid up front and show one. The sets are small and this
        // makes switching instant, which is what a tab strip implies.
        let tabs: [AssetTab] = showsTabs ? AssetTab.allCases : [.sources]
        for tab in tabs {
            let grid = makeGrid(for: contents(of: tab, sources: items))
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.isHidden = tab != currentTab
            document.addSubview(grid)
            gridsByTab[tab] = grid

            let empty = Controls.label(
                tab.emptyMessage, font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.isHidden = tab != currentTab || !contents(of: tab, sources: items).isEmpty
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 3
            document.addSubview(empty)
            emptyLabelsByTab[tab] = empty

            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: document.topAnchor),
                grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
                empty.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
                empty.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
                empty.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4)
            ])
        }

        // The document's height follows whichever grid is showing.
        if let first = gridsByTab[currentTab] {
            documentHeight = document.heightAnchor.constraint(
                greaterThanOrEqualTo: first.heightAnchor)
            documentHeight?.isActive = true
        }

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor)
        ])

        _ = tabControl
    }

    private var documentHeight: NSLayoutConstraint?

    /// What each tab contains.
    private func contents(of tab: AssetTab, sources: [LibraryItem]) -> [LibraryItem] {
        switch tab {
        case .sources:
            return sources
        case .generators:
            // Every generator is real and assignable, so they are all available.
            return GeneratorKind.allCases.map {
                LibraryItem(name: $0.displayName, badge: "GEN", isAvailable: true)
            }
        case .graphics, .clips, .images:
            // Empty on purpose; the tab says why rather than showing a blank box.
            return []
        }
    }

    /// Builds one uniform grid of items.
    private func makeGrid(for items: [LibraryItem]) -> NSView {
        let itemsStack = NSStackView()
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = Theme.Metrics.thumbnailGap

        var row: [NSView] = []
        for item in items {
            row.append(LibraryItemView(item: item))
            if row.count == columns {
                itemsStack.addArrangedSubview(Controls.row(row, spacing: Theme.Metrics.thumbnailGap))
                row = []
            }
        }
        if !row.isEmpty {
            itemsStack.addArrangedSubview(
                Controls.row(row + [Controls.spacer()], spacing: Theme.Metrics.thumbnailGap))
        }
        return itemsStack
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < AssetTab.allCases.count else { return }
        let tab = AssetTab.allCases[index]
        guard tab != currentTab else { return }

        gridsByTab[currentTab]?.isHidden = true
        emptyLabelsByTab[currentTab]?.isHidden = true
        currentTab = tab

        let grid = gridsByTab[tab]
        grid?.isHidden = false
        // The empty message shows only when there is genuinely nothing to show.
        let isEmpty = (grid as? NSStackView)?.arrangedSubviews.isEmpty ?? true
        emptyLabelsByTab[tab]?.isHidden = !isEmpty

        // Re-point the document's height at whichever grid is now visible.
        documentHeight?.isActive = false
        if let grid {
            documentHeight = grid.superview?.heightAnchor.constraint(
                greaterThanOrEqualTo: grid.heightAnchor)
            documentHeight?.isActive = true
        }
        Log.info(.app, "asset browser showing \(tab.displayName)")
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        // Filtering is not built; saying so beats silently ignoring what was typed.
        guard !sender.stringValue.isEmpty else { return }
        Log.info(.app, "library search is not built yet (typed: \(sender.stringValue))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}
