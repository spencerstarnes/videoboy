//
//  AppDelegate.swift — application lifecycle and the menu bar.
//
//  Purpose : Creates the main window and the menu bar, and logs the environment once
//            at startup so any later bug report has the context attached.
//  Inputs  : none beyond launch.
//  Outputs : a visible main window.
//  Connects: MainWindowController (the canonical shell, SPEC 14).
//  Extend  : menu items go in `buildMenuBar`. Window construction belongs in
//            MainWindowController, not here.
//

import AppKit
import VideoboyCore

/// Owns the application's windows and menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var launchWindowController: LaunchWindowController?
    private var preferencesController: PreferencesWindowController?

    /// Settings that outlive a patch. Loaded once, here, and handed to whoever needs
    /// them — one store, so a change made in the window is seen everywhere at once.
    let preferences = PreferenceStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch screen goes up first and reports each subsystem as it comes up.
        // Startup is not instant — Metal compiles its shaders, the DV codec opens,
        // MIDI enumerates — and showing what is happening turns that pause into
        // information rather than a hang.
        let launch = LaunchWindowController()
        launch.showWindow(nil)
        launchWindowController = launch

        logEnvironment()

        if MetalContext.shared != nil {
            launch.complete(.metal)
            launch.complete(.shaders)
        } else {
            launch.skip(.metal, reason: "unavailable")
            launch.skip(.shaders, reason: "no device")
        }

        // The codec is checked rather than assumed: a missing DV decoder is the kind
        // of thing that should be visible at launch, not when a file fails to open.
        if (try? DVDecoder()) != nil {
            launch.complete(.codecs)
        } else {
            launch.skip(.codecs, reason: "DV decoder missing")
        }

        buildMenuBar()

        let controller = MainWindowController()
        launch.complete(.graph)
        launch.complete(.clock)

        if controller.engine.midi.connectedSourceNames.isEmpty {
            launch.skip(.midi, reason: "no devices")
        } else {
            launch.complete(.midi)
        }

        let displays = DisplayRouter.availableDisplays()
        if displays.isEmpty {
            launch.skip(.displays, reason: "none found")
        } else {
            launch.complete(.displays)
        }

        controller.showWindow(nil)
        mainWindowController = controller
        launch.complete(.interface)

        NSApp.activate(ignoringOtherApps: true)
        Log.info(.app, "main window shown")

        // Leave it up just long enough to be read, then fade. Not padding: by this
        // point the app is fully live behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.launchWindowController?.dismiss()
            self?.launchWindowController = nil
        }
    }

    /// Quitting when the window closes is right for a single-window instrument.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Records what this build is and what it can see, once, at startup.
    private func logEnvironment() {
        Log.info(.app, "Videoboy \(Videoboy.version) starting")
        let flags = FeatureFlags.current.enabled.map(\.rawValue).sorted()
        Log.info(.app, "feature flags on: \(flags.joined(separator: ", "))")

        if MetalContext.shared == nil {
            Log.error(.render, "Metal is unavailable; previews and output will stay blank")
        }
        for display in DisplayRouter.availableDisplays() {
            Log.info(.output, "display '\(display.name)' \(display.modeDescription)\(display.isMain ? " [main]" : "")")
        }
    }

    /// Opens the Preferences window, reusing it if it is already open.
    @objc private func showPreferences() {
        guard let engine = mainWindowController?.engine else {
            Log.warn(.app, "no engine yet; cannot open preferences")
            return
        }
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(
                store: preferences, engine: engine)
        }
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Builds the menu bar shown in the mockup's system bar: File, Edit, Workspace,
    /// Templates, Window, Help. Items whose features are not built yet are present
    /// but disabled, per CLAUDE.md — never omitted.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // Application menu. Its title is taken from the bundle name by AppKit.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Videoboy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Comma, because that is where every Mac user's hand already goes.
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Videoboy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Videoboy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // The remaining menus mirror the mockup. Their contents arrive with the
        // features they drive; until then they are visibly present and disabled.
        for title in ["File", "Edit", "Workspace", "Templates"] {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            let placeholder = NSMenuItem(title: "Not yet implemented", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            item.submenu = submenu
            mainMenu.addItem(item)
        }

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let firstRun = NSMenuItem(title: "First Run Notes (docs/FIRST-RUN.md)", action: nil, keyEquivalent: "")
        firstRun.isEnabled = false
        helpMenu.addItem(firstRun)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
