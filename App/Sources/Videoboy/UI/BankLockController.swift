//
//  BankLockController.swift — LOCK in the window (setlist plan §7).
//
//  Purpose : Makes a locked side ignore everything that could change its picture,
//            through the three ways in: a CLICK or a KEY on its panels (one event
//            monitor, so no control has to know about LOCK), MIDI (BankLock answers
//            ParamRegistry.refusesDelivery), and LOADS (ShellController and the pads
//            ask `refusesLoad` / `refusesPad`). A refused touch blinks that side's LOCK
//            key, so nothing happening is explained. Locked panels show a padlock.
//  Inputs  : the two LOCK keys (click, or MIDI 6CJ/6DJ read on the tick).
//  Outputs : swallowed events; padlocks; `lock` for everyone else to ask.
//  Connects: BankLock (Core, the rules), LockStrip (the keys), PanelView (padlocks),
//            ShellController (owns this; loads and undo ask it), ClipPadController.
//  Extend  : a new control on a side's panels is covered by being inside them. A new
//            control OUTSIDE them that changes a side's picture needs adding to
//            `regions(for:)`, and a new way of loading needs to ask `refusesLoad`.
//
//  What still works on a locked side, on purpose: the picture (clips play, LFOs and
//  sweeps and beat-armed pads keep going), Program (so the side can be taken to air
//  or away), monitors and their scope keys, collapsing a panel, Shift-click MIDI
//  learn, Settings. The lock is never saved.
//

import AppKit
import VideoboyCore

final class BankLockController {

    /// The rules, and which sides are locked.
    let lock = BankLock()

    private unowned let shell: ShellController
    private let engine: Engine
    private var monitor: Any?

    /// Touches refused, by side — self-QA.
    private(set) var refusedTouches: [Bank: Int] = [:]

    init(shell: ShellController, engine: Engine) {
        self.shell = shell
        self.engine = engine

        // The keys' own codes, so Shift-click learns them and MIDI can toggle them.
        engine.registry.register(slot: BankLock.slot, parameters: Bank.allCases.map {
            Parameter(code: BankLock.code(for: $0), range: 0...1, defaultValue: 0)
        })
        engine.registry.refusesDelivery = { [weak self] slot, code in
            self?.lock.refuses(slot: slot, code: code) ?? false
        }

        let toolbar = shell.shell.toolbar
        for bank in Bank.allCases {
            toolbar.lockStrip(bank).onToggled = { [weak self] locked in self?.lock.setLocked(locked, bank) }
        }
        lock.onChange = { [weak self] bank, locked in self?.show(bank, locked: locked) }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.refuses(event) ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Locking

    func setLocked(_ locked: Bool, _ bank: Bank) { lock.setLocked(locked, bank) }

    /// MIDI 6CJ / 6DJ: a press toggles, exactly as Hot Punch's 6BJ does. Two
    /// dictionary reads a frame.
    func tick() {
        for bank in Bank.allCases {
            let code = BankLock.code(for: bank)
            guard let value = engine.registry.value(slot: BankLock.slot, code: code), value > 0.5 else { continue }
            engine.registry.setValue(0, slot: BankLock.slot, code: code)
            lock.toggle(bank)
            Log.info(.midi, "LOCK \(bank.displayName) toggled from a mapping")
        }
    }

    private func show(_ bank: Bank, locked: Bool) {
        shell.shell.toolbar.lockStrip(bank).setLocked(locked)
        for panel in panels(for: bank) { panel.setLocked(locked) }
    }

    // MARK: - Asking

    /// For a load or a Queue change aimed at `channel`: true (and a blink) when its
    /// side is locked.
    func refusesLoad(channel: String) -> Bool {
        guard lock.refuses(channel: channel), let bank = Bank.containing(channel: channel) else { return false }
        refuse(bank, "load into \(channel)")
        return true
    }

    /// For a pad press or drop by a person (never the beat): true when refused.
    func refusesPad(_ index: Int) -> Bool {
        guard lock.refuses(padIndex: index),
              let bank = Bank.allCases.first(where: { $0.padIndices.contains(index) }) else { return false }
        refuse(bank, "pad \(index + 1)")
        return true
    }

    /// For anything applying parameter values by hand (undo, redo): true when one of
    /// them is on a locked side.
    func refusesValues(_ changes: [ParameterChange], what: String) -> Bool {
        guard let bank = changes.lazy.compactMap({ BankLock.bank(forSlot: $0.slot, code: $0.code) })
            .first(where: { self.lock.isLocked($0) }) else { return false }
        refuse(bank, what)
        return true
    }

    /// Blinks the side's LOCK key: the reason nothing happened.
    func refuse(_ bank: Bank, _ what: String) {
        refusedTouches[bank, default: 0] += 1
        shell.shell.toolbar.lockStrip(bank).blink()
        Log.info(.app, "\(bank.displayName) is locked — refused \(what)")
    }

    // MARK: - Clicks and keys

    /// The panels a side's padlock shows on.
    private func panels(for bank: Bank) -> [PanelView] {
        let panels = shell.shell.grid.panels
        return bank == .ab
            ? [panels.sourceA, panels.sourceB, panels.faderAB, panels.effectsOne]
            : [panels.sourceC, panels.sourceD, panels.faderCD, panels.effectsTwo]
    }

    /// Everything a click is refused inside: the side's panels, the swap key
    /// between its sources, and its pads.
    private func regions(for bank: Bank) -> [NSView] {
        let set = shell.shell.grid.panels
        let toolbar = shell.shell.toolbar
        return panels(for: bank) + (bank == .ab
            ? [set.swapAB, toolbar.leftPads]
            : [set.swapCD, toolbar.rightPads])
    }

    /// The locked side a view belongs to, or nil if it is free to use.
    func lockedBank(containing view: NSView) -> Bank? {
        guard !lock.locked.isEmpty else { return nil }
        let exempt: [NSView] = Bank.allCases.flatMap { panels(for: $0).map(\.collapseControl) }
        var current: NSView? = view
        while let candidate = current {
            if exempt.contains(where: { $0 === candidate }) { return nil }
            for bank in lock.locked where regions(for: bank).contains(where: { $0 === candidate }) {
                return bank
            }
            current = candidate.superview
        }
        return nil
    }

    /// Whether an event must be swallowed: a click on, or a key typed into, a
    /// locked side. Separate from the monitor so self-QA can route real events.
    func refuses(_ event: NSEvent) -> Bool {
        guard !lock.locked.isEmpty, let window = shell.shell.window, event.window === window else {
            return false
        }
        switch event.type {
        case .keyDown:
            // Menu keys (⌘Z, ⌘S, ⌘1–3) are not typing into a control.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.command), !flags.contains(.control),
                  let responder = window.firstResponder as? NSView, !(responder is NSText),
                  let bank = lockedBank(containing: responder) else { return false }
            refuse(bank, "a key on \(type(of: responder))")
            return true
        default:
            // Shift-click learns a control to MIDI, which keeps working while locked.
            if shell.detectSession?.isArmed == true { return false }
            guard let content = window.contentView,
                  let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                            ?? event.locationInWindow),
                  let bank = lockedBank(containing: hit) else { return false }
            refuse(bank, "a click on \(type(of: hit))")
            return true
        }
    }
}
