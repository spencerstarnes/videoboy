//
//  ModeController.swift — switches the window between Import, VJ and Settings.
//
//  Purpose : Proposal §4. The mode bar (and ⌘1–⌘3) show one of three things in the
//            grid's place. Only views change: the engine is never stopped, paused,
//            rebuilt or reloaded, so output and recording carry on through any
//            switch. The VJ grid is hidden, not torn down, and its previews stop
//            presenting while hidden (MetalPreviewView skips hidden views).
//  Inputs  : the shell, the preference store, the engine (only handed to Settings).
//  Outputs : which mode is showing.
//  Connects: StatusBarView.onModeSelected, AppDelegate's View menu, ImportModeView,
//            PreferencesWindowController (embedded as Settings).
//  Extend  : a new mode's view is built lazily in `view(for:)`.
//

import AppKit
import VideoboyCore

/// Owns the current mode of one main window.
final class ModeController: NSObject {

    private unowned let shell: ShellView
    private let store: PreferenceStore
    private unowned let engine: Engine

    private(set) var mode: AppMode = .vj
    /// Built on first visit.
    private var importView: ImportModeView?
    private(set) var settings: PreferencesWindowController?

    /// Set by the owner: the setup assistant's "run again" and the preview fill.
    var onRunSetupAssistant: (() -> Void)?
    var onPreviewFillChanged: ((PreviewFill) -> Void)?
    /// Runs an Import-mode import (the shell's background ImportJob). Set by the owner.
    var onImport: ((_ urls: [URL], _ method: ImportMethod, _ destination: URL?, _ bin: String?,
                    _ optimize: OptimizePreset?) -> Void)?
    /// Import mode's view, once built — for self-QA.
    var importViewForChecks: ImportModeView? { importView }
    /// Called after every switch (menu check marks).
    var onModeChanged: ((AppMode) -> Void)?

    init(shell: ShellView, store: PreferenceStore, engine: Engine) {
        self.shell = shell
        self.store = store
        self.engine = engine
        super.init()
        shell.statusBar.onModeSelected = { [weak self] mode in self?.show(mode) }
    }

    /// Shows a mode. Cheap and idempotent; never touches the engine.
    ///
    /// Nothing is rebuilt or re-laid-out on a switch: each mode's view is installed in
    /// the host once, on first visit, and afterwards only its `isHidden` changes. The
    /// grid is never hidden either — the opaque host covers it. Hiding the grid and
    /// re-adding views cost 22–35 ms of main thread per switch and dropped a refresh
    /// (measured, `selfqa modes`), because unhiding 1,300 controls re-lays-out them all.
    func show(_ newMode: AppMode) {
        shell.statusBar.setMode(newMode)
        guard newMode != mode else { return }
        mode = newMode
        let host = shell.modeHost
        if let content = view(for: newMode), content.superview !== host {
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
        }
        let showing = view(for: newMode)
        for child in host.subviews { child.isHidden = child !== showing }
        host.isHidden = newMode == .vj
        // The covered grid's previews stop presenting (they are occluded, and a hidden
        // preview skips its `nextDrawable`); nothing about the engine changes.
        shell.grid.previewsCovered = newMode != .vj
        Log.info(.app, "mode: \(newMode.menuTitle)")
        onModeChanged?(newMode)
    }

    /// Shows Settings on a given pane (⌘, lands here when the mode bar is on).
    func showSettings(_ pane: PreferencesWindowController.Pane? = nil) {
        show(.settings)
        if let pane { settings?.select(pane) }
    }

    /// The View menu's mode items: Import ⌘1 · VJ ⌘2 · Settings ⌘3. Each item's tag is
    /// its mode's raw value. Built here so the app's menu and the self-QA use one maker.
    static func makeViewMenu(target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "View")
        for mode in AppMode.allCases {
            let entry = NSMenuItem(title: mode.menuTitle, action: action, keyEquivalent: mode.keyEquivalent)
            entry.keyEquivalentModifierMask = .command
            entry.tag = mode.rawValue
            entry.target = target
            entry.state = mode == .vj ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    /// A View-menu item was chosen (its tag is the mode).
    @objc func menuChosen(_ sender: NSMenuItem) {
        guard let mode = AppMode(rawValue: sender.tag) else { return }
        show(mode)
    }

    private func view(for mode: AppMode) -> NSView? {
        switch mode {
        case .vj:
            return nil
        case .importMedia:
            if importView == nil {
                let view = ImportModeView(store: store, library: shell.grid.panels.library)
                view.onImport = { [weak self] urls, method, destination, bin, optimize in
                    self?.onImport?(urls, method, destination, bin, optimize)
                }
                importView = view
            }
            return importView
        case .settings:
            if settings == nil {
                let controller = PreferencesWindowController(store: store, engine: engine)
                controller.onRunSetupAssistant = { [weak self] in self?.onRunSetupAssistant?() }
                controller.onPreviewFillChanged = { [weak self] fill in self?.onPreviewFillChanged?(fill) }
                settings = controller
                _ = controller.detachRootViewForEmbedding()
            }
            return settings?.rootView
        }
    }
}
