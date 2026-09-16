//
//  ShellView.swift — the canonical window shell (SPEC 14, normative).
//
//  Purpose : Toolbar on top, the 5x5 panel grid in the middle, status bar below.
//            This is the arrangement from docs/mockups/layout-v6.html and it does
//            not get redesigned or simplified.
//  Inputs  : none yet; later phases wire panels to the graph.
//  Outputs : the window's content view.
//  Connects: Theme for every measurement; PanelGridView for the grid itself.
//  Extend  : add panels inside PanelGridView. The three-band arrangement here is fixed.
//

import AppKit
import VideoboyCore

/// The window's content: transport toolbar, panel grid, status bar.
final class ShellView: NSView {

    private let toolbar = TransportToolbarView()
    private let grid = PanelGridView()
    private let statusBar = StatusBarView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.content.cgColor

        for child in [toolbar, grid, statusBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolbarHeight),

            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: grid.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.statusBarHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShellView is created in code, never from a nib")
    }
}
