//
//  ModulationMenus.swift — the menus behind the M / S / C mapping badges.
//
//  Purpose : Assigning a MIDI control, an audio tap or an LFO to a parameter is the
//            point at which this stops being a video player and becomes an
//            instrument. All three engines existed and were tested before this file;
//            it is what lets a performer reach them without editing code.
//  Inputs  : which parameter was clicked and which badge.
//  Outputs : menu selections, delivered through callbacks.
//  Connects: ShellController (which owns the engine), MIDIInput, AudioReactivityBus,
//            LFOBank.
//  Extend  : a new modulation source is a new badge letter and a new menu builder
//            here. The assignment itself belongs in the engine, not in this file.
//

import AppKit
import VideoboyCore

/// Builds and presents the modulation menus.
enum ModulationMenus {

    /// What the performer chose from a menu.
    enum Choice {
        /// Arm MIDI detect for this parameter.
        case learnMIDI
        /// Bind an audio tap with a shape.
        case audio(tap: ReactivityTap, shape: ReactivityShape)
        /// Bind an LFO.
        case lfo(shape: LFOShape, rate: LFORate)
        /// Remove whatever is driving this parameter from that source.
        case clear
    }

    /// Shows the menu for a badge, anchored to the badge itself.
    ///
    /// - Parameters:
    ///   - badge: "M", "S" or "C".
    ///   - isCurrentlyDriven: whether to offer a Remove item.
    ///   - view: the badge, used to position the menu.
    ///   - handler: called with the choice, or not at all if the menu is dismissed.
    static func present(
        badge: String,
        isCurrentlyDriven: Bool,
        from view: NSView,
        handler: @escaping (Choice) -> Void
    ) {
        let menu: NSMenu
        switch badge {
        case "M": menu = midiMenu(isCurrentlyDriven: isCurrentlyDriven, handler: handler)
        case "S": menu = audioMenu(isCurrentlyDriven: isCurrentlyDriven, handler: handler)
        case "C": menu = lfoMenu(isCurrentlyDriven: isCurrentlyDriven, handler: handler)
        default: return
        }
        // Anchored just below the badge so the menu does not cover the row it
        // belongs to, which matters when the parameter is being watched live.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    // MARK: - Menus

    private static func midiMenu(
        isCurrentlyDriven: Bool, handler: @escaping (Choice) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem("Learn — move a control…", handler: handler, choice: .learnMIDI))
        if isCurrentlyDriven {
            menu.addItem(.separator())
            menu.addItem(actionItem("Remove MIDI mapping", handler: handler, choice: .clear))
        }
        return menu
    }

    private static func audioMenu(
        isCurrentlyDriven: Bool, handler: @escaping (Choice) -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        // The taps worth reaching for directly, each with the shape that suits it.
        // Pairing them removes a submenu and a decision: an onset wants a pulse, a
        // level wants an envelope. Anything else is available under "More".
        let quickChoices: [(String, ReactivityTap, ReactivityShape)] = [
            ("Level (envelope)", .rms, .envelope),
            ("Onset (pulse)", .onset, .pulse),
            ("Bass (envelope)", .band(index: 1), .envelope),
            ("Treble (envelope)", .band(index: 5), .envelope)
        ]
        for (title, tap, shape) in quickChoices {
            menu.addItem(actionItem(title, handler: handler, choice: .audio(tap: tap, shape: shape)))
        }

        menu.addItem(.separator())
        let moreItem = NSMenuItem(title: "More…", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()
        var taps: [(String, ReactivityTap)] = [("RMS", .rms), ("Peak", .peak), ("Onset", .onset)]
        for index in 0..<AudioAnalyzer.bandCount {
            let low = Int(AudioAnalyzer.bandEdges[index])
            let high = Int(AudioAnalyzer.bandEdges[index + 1])
            taps.append(("Band \(index + 1) (\(low)–\(high) Hz)", .band(index: index)))
        }
        for (tapTitle, tap) in taps {
            let tapItem = NSMenuItem(title: tapTitle, action: nil, keyEquivalent: "")
            let shapeMenu = NSMenu()
            for shape in ReactivityShape.allCases {
                shapeMenu.addItem(actionItem(
                    shape.displayName, handler: handler, choice: .audio(tap: tap, shape: shape)))
            }
            tapItem.submenu = shapeMenu
            moreMenu.addItem(tapItem)
        }
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)

        if isCurrentlyDriven {
            menu.addItem(.separator())
            menu.addItem(actionItem("Remove audio mapping", handler: handler, choice: .clear))
        }
        return menu
    }

    private static func lfoMenu(
        isCurrentlyDriven: Bool, handler: @escaping (Choice) -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        // Shape first, then rate: that is the order the decision is actually made in.
        for shape in LFOShape.allCases {
            let shapeItem = NSMenuItem(title: shape.displayName, action: nil, keyEquivalent: "")
            let rateMenu = NSMenu()
            for subdivision in Subdivision.allCases {
                rateMenu.addItem(actionItem(
                    subdivision.rawValue, handler: handler,
                    choice: .lfo(shape: shape, rate: .subdivision(subdivision))))
            }
            rateMenu.addItem(.separator())
            // A couple of free-running rates for motion that should not be musical.
            for hertz in [0.1, 0.5, 2.0] {
                rateMenu.addItem(actionItem(
                    String(format: "%.1f Hz (free)", hertz), handler: handler,
                    choice: .lfo(shape: shape, rate: .free(hertz: hertz))))
            }
            shapeItem.submenu = rateMenu
            menu.addItem(shapeItem)
        }

        if isCurrentlyDriven {
            menu.addItem(.separator())
            menu.addItem(actionItem("Remove LFO", handler: handler, choice: .clear))
        }
        return menu
    }

    // MARK: - Plumbing

    /// A menu item that calls the handler with a fixed choice.
    ///
    /// AppKit menu items want a target and a selector; carrying a closure instead
    /// keeps the choice next to the title that describes it, which is why this small
    /// wrapper exists rather than a pile of `@objc` methods and tag arithmetic.
    private static func actionItem(
        _ title: String, handler: @escaping (Choice) -> Void, choice: Choice
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire), keyEquivalent: "")
        let target = ClosureMenuTarget { handler(choice) }
        item.target = target
        // The item owns its target, or ARC would release it the moment this returns
        // and the menu would do nothing when clicked.
        item.representedObject = target
        return item
    }
}

/// Holds a closure so an `NSMenuItem` can call it.
final class ClosureMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() { action() }
}
