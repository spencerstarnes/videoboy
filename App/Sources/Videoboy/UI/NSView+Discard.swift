//
//  NSView+Discard.swift — taking a view out of the window for good.
//
//  Purpose : AppKit's tooltip manager keeps a STRONG reference to every view whose
//            `toolTip` has been set, keyed by the view. A view merely removed from its
//            superview stays registered there and is never freed — along with its
//            subviews, constraints and observers. Every panel that rebuilds its
//            controls (Source Controls on each clip load, the effect chain, playlists)
//            leaked its old controls this way: ~8 MB/min on a soak (found with `heap` and
//            `leaks --traceTree`, 0.4.7).
//  Inputs  : a view that will not be shown again.
//  Outputs : the view out of its superview, and out of the tooltip manager.
//  Connects: every rebuild that throws views away.
//  Extend  : use `discardFromSuperview()` wherever views are thrown away; plain
//            `removeFromSuperview()` only where the same view will be put back (a
//            cached pane, a card lifted for a drag).
//

import AppKit

extension NSView {

    /// Removes this view for good: clears the tooltips of it and everything inside it
    /// (so the tooltip manager lets go of them), then removes it from its superview.
    func discardFromSuperview() {
        Self.clearToolTips(in: self)
        removeFromSuperview()
    }

    private static func clearToolTips(in view: NSView) {
        if view.toolTip != nil { view.toolTip = nil }
        view.removeAllToolTips()
        for subview in view.subviews { clearToolTips(in: subview) }
    }
}
