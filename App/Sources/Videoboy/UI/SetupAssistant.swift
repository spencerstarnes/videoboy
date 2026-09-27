//
//  SetupAssistant.swift — first launch, re-runnable from Settings (proposal §8).
//
//  Purpose : One sheet, five pages: Welcome · Locations · Project · Optimize · Done.
//            Defaults everywhere, so Continue ▸ Continue ▸ … ▸ Done works without
//            reading. Replaces the first-run "pick a templates folder" alert when the
//            mode bar is on.
//  Inputs  : a PreferenceStore.
//  Outputs : locations written through the store; `setupCompleted` set on Done.
//  Connects: AppDelegate (first launch), ModeController (Settings ▸ Project ▸ Run
//            Setup Assistant…), SetupPanes (the shared choices and LocationRow).
//  Extend  : a page is a case in `Page` and a builder in `makePage`.
//
//  It is a SHEET (`beginSheet`), never `runModal`: the main thread keeps running and
//  so does the show behind it (BUGHUNT S6).
//

import AppKit
import VideoboyCore

/// The setup assistant.
final class SetupAssistant: NSWindowController {

    enum Page: Int, CaseIterable {
        case welcome, locations, project, optimize, done
    }

    private let store: PreferenceStore
    private(set) var page: Page = .welcome
    private let pageHost = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let openImportButton = NSButton(title: "Open Import (⌘1)", target: nil, action: nil)

    /// Called when the sheet closes; `openImport` when the person chose to.
    var onFinish: ((_ openImport: Bool) -> Void)?

    init(store: PreferenceStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.Color.content
        window.title = "Set Up Videoboy"
        super.init(window: window)
        buildLayout()
        show(.welcome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Presents the assistant as a sheet on `parent`.
    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pageHost)
        for button in [backButton, continueButton, openImportButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        backButton.action = #selector(backPressed)
        continueButton.action = #selector(continuePressed)
        continueButton.keyEquivalent = "\r"
        continueButton.setAccessibilityIdentifier("setup-continue")
        openImportButton.action = #selector(openImportPressed)
        let buttons = Controls.row([openImportButton, Controls.spacer(), backButton, continueButton], spacing: 10)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            pageHost.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            pageHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            pageHost.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func show(_ newPage: Page) {
        page = newPage
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        let view = makePage(newPage)
        view.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor)
        ])
        backButton.isEnabled = newPage != .welcome
        continueButton.title = newPage == .done ? "Done" : "Continue"
        // Present on every page so the row never shifts; usable only at the end.
        openImportButton.isEnabled = newPage == .done
    }

    private func heading(_ title: String, _ detail: String) -> [NSView] {
        [Controls.label(title, font: Theme.Font.panelTitle, color: Theme.Color.textPrimary),
         Controls.note(detail, width: 540)]
    }

    private func makePage(_ page: Page) -> NSView {
        let preferences = store.preferences
        var views: [NSView]
        switch page {
        case .welcome:
            views = heading("Welcome to Videoboy",
                "A few choices, all with sensible defaults — Continue through to accept them. "
                + "Everything here can be changed later in Settings (⌘3).")
        case .locations:
            views = heading("Locations", "Where Videoboy keeps things. Stored folders are "
                + "never moved or deleted by changing these.")
            views += [
                LocationRow(caption: "Save / Templates",
                            current: preferences.saveLocation ?? Preferences.defaultMoviesFolder
                                .appendingPathComponent("Templates", isDirectory: true),
                            prompt: "Where should templates be saved?") { [weak self] url in
                    self?.store.preferences.saveLocation = url },
                LocationRow(caption: "Plugins",
                            current: preferences.pluginsLocationPath.map { URL(fileURLWithPath: $0) }
                                ?? Preferences.defaultMoviesFolder.appendingPathComponent("Plugins"),
                            prompt: "Where are ISF plugins kept?") { [weak self] url in
                    self?.store.preferences.pluginsLocationPath = url.path },
                LocationRow(caption: "Library", current: preferences.catalogURL,
                            prompt: "Where should the library catalog live?", choosesFiles: true) { [weak self] url in
                    self?.store.preferences.libraryLocationPath = url.path },
                LocationRow(caption: "Media", current: preferences.mediaLocation,
                            prompt: "Where should copied clips go?") { [weak self] url in
                    self?.store.preferences.mediaLocationPath = url.path },
                LocationRow(caption: "Optimized media", current: preferences.optimizedMediaLocation,
                            prompt: "Where should optimized media be written?") { [weak self] url in
                    self?.store.preferences.optimizedMediaLocationPath = url.path }
            ]
        case .project:
            views = heading("Project", SetupChoices.canvasReason)
            views += [Controls.row([Controls.label("Canvas"), SetupChoices.popUp(SetupChoices.canvases)]),
                      Controls.row([Controls.label("Frame rate"), SetupChoices.popUp(SetupChoices.frameRates)])]
        case .optimize:
            let preset = SetupChoices.popUp(SetupChoices.optimizePresetItems)
            preset.selectItem(at: store.preferences.optimizePreset == OptimizePreset.compact.rawValue ? 1 : 0)
            preset.target = self
            preset.action = #selector(presetChosen(_:))
            views = heading("Optimize", "What Copy + Optimize writes. Performance writes DV on the "
                + "SD NTSC canvas (keeps the DV wedge); Compact writes MPEG-2 at a third of the size.")
            views += [Controls.row([Controls.label("Preset"), preset])]
        case .done:
            views = heading("Ready", "Canvas SD NTSC 29.97 · library at "
                + store.preferences.catalogURL.path
                + ". Open Import to bring clips in, or Done to start in VJ.")
        }
        return Controls.column(views, spacing: 10)
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        if let preset = SetupChoices.optimizePreset(at: sender.indexOfSelectedItem) {
            store.preferences.optimizePreset = preset.rawValue
        }
    }

    @objc private func backPressed() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        show(previous)
    }

    @objc func continuePressed() {
        if let next = Page(rawValue: page.rawValue + 1) {
            show(next)
        } else {
            finish(openImport: false)
        }
    }

    @objc private func openImportPressed() { finish(openImport: true) }

    /// Writes the defaults for anything left unchosen, marks setup done, closes.
    private func finish(openImport: Bool) {
        if store.preferences.mediaLocationPath == nil {
            store.preferences.mediaLocationPath = store.preferences.mediaLocation.path
        }
        if store.preferences.optimizedMediaLocationPath == nil {
            store.preferences.optimizedMediaLocationPath = store.preferences.optimizedMediaLocation.path
        }
        store.preferences.setupCompleted = true
        Log.info(.app, "setup assistant finished")
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        onFinish?(openImport)
    }
}
