//
//  FlippedView.swift — a container whose origin is the top-left.
//
//  Purpose : AppKit views are bottom-left origin, so a stack placed inside an
//            NSScrollView settles at the bottom and grows downward off-screen. Every
//            scrolling list in this app wants the opposite. This is the one-line fix,
//            kept in its own file so the reason is written down once.
//  Inputs  : subviews, as any NSView.
//  Outputs : the same, laid out from the top.
//  Connects: EffectChainPanelBody and LibraryPanelBody use it as their document view.
//  Extend  : nothing to extend — it exists only to flip the coordinate system.
//

import AppKit

/// A plain container view that lays out from the top down.
/// Subclassed by `LibraryDropView`, which adds drop handling, so this is open
/// rather than final.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
