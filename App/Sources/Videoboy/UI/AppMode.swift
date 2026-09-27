//
//  AppMode.swift — the three modes of the window (proposal §4).
//
//  Purpose : Import · VJ · Settings, as Resolve has pages. One enum so the mode bar,
//            the View menu and ⌘1–⌘3 cannot disagree about order, names or keys.
//  Inputs  : none.
//  Outputs : titles, SF Symbols, key equivalents.
//  Connects: StatusBarView (mode bar), ModeController (switching), AppDelegate (menu).
//  Extend  : a new mode is a case here (the bar has room for five), a view for it in
//            ModeController, and nothing else.
//

import Foundation

/// A mode of the main window. The raw value is its ⌘-digit.
enum AppMode: Int, CaseIterable {
    case importMedia = 1
    case vj = 2
    case settings = 3

    /// The label on the mode bar and in the View menu.
    var title: String {
        switch self {
        case .importMedia: "IMPORT"
        case .vj: "VJ"
        case .settings: "SETTINGS"
        }
    }

    /// The View menu's wording.
    var menuTitle: String {
        switch self {
        case .importMedia: "Import"
        case .vj: "VJ"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .importMedia: "square.and.arrow.down"
        case .vj: "square.grid.3x3"
        case .settings: "gearshape"
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    var keyEquivalent: String { String(rawValue) }
}
