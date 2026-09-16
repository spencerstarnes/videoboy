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

/// A library grid with a toolbar above it.
final class LibraryPanelBody: NSView {

    private let grid = NSGridView()

    /// - Parameters:
    ///   - items: what to show.
    ///   - columns: 3 for the sub-mix libraries, 6 for the central browser.
    ///   - showsTabs: true for the asset browser, which is tabbed by asset kind.
    init(items: [LibraryItem], columns: Int, showsTabs: Bool) {
        super.init(frame: .zero)

        var header: [NSView] = []
        if showsTabs {
            // SPEC 14.2's browser tabs. Emulators appear once 18.2 ships.
            header.append(Controls.segmented(
                ["Sources", "Generators", "VSTs", "Graphics", "Clips", "Images"],
                selected: 0, enabled: false
            ))
        } else {
            header.append(Controls.popUp(["Page 1"], enabled: false))
        }
        let search = Controls.searchField(placeholder: showsTabs ? "Search library…" : "Search…", enabled: false)
        header.append(search)
        if showsTabs {
            header.append(Controls.button("Import…", enabled: false))
            header.append(Controls.segmented(["⊞", "≣"], selected: 0, enabled: false))
        }
        let headerRow = Controls.row(header, spacing: 4)
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)

        // A uniform grid: fixed-width cells, tight gaps, left-aligned rows. Built
        // from stacks rather than NSGridView because NSGridView sizes columns to
        // their content, which is exactly the inconsistency being removed.
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
            // The final row is left-aligned, not stretched: padding it with spacers
            // would space the real items out differently from every row above.
            let rowStack = Controls.row(row + [Controls.spacer()], spacing: Theme.Metrics.thumbnailGap)
            itemsStack.addArrangedSubview(rowStack)
        }

        // A flipped document view keeps the grid anchored to the top of the panel.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(itemsStack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

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
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            itemsStack.topAnchor.constraint(equalTo: document.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            itemsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }
}
