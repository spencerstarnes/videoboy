//
//  VBSwitch.swift — a switch you can drag across, as in Blender.
//
//  Purpose : Setting eight toggles should not need eight separate clicks. Blender
//            lets you press on one checkbox and sweep the pointer across its
//            neighbours, setting them all to whatever the first one became. It is a
//            small thing that removes a lot of clicking on a dense control surface,
//            and this makes it the behaviour of every switch in the app rather than
//            a special case in one panel.
//  Inputs  : mouse press and drag.
//  Outputs : target/action per switch changed, exactly as `NSSwitch` would send.
//  Connects: Controls.toggle builds these; every panel gets the behaviour for free.
//
//  How it works: the first switch pressed decides the value being painted and opens
//  a shared session. While the mouse is down, every switch the pointer enters is set
//  to that same value — set, not toggled, so sweeping back over one does not flip it
//  again. That is what makes the gesture predictable.
//

import AppKit
import VideoboyCore

/// A switch that participates in drag-across gestures.
final class VBSwitch: NSSwitch {

    /// The value being painted by the gesture in progress, if any.
    ///
    /// Static because the gesture spans several switches: the one you pressed and
    /// every one you sweep over. It lives only for the duration of the drag.
    private static var paintingValue: NSControl.StateValue?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }

        // The switch under the mouse decides the value for the whole sweep.
        let newValue: NSControl.StateValue = (state == .on) ? .off : .on
        VBSwitch.paintingValue = newValue
        apply(newValue)

        // Track the drag here rather than via mouseDragged: the pointer spends the
        // gesture over OTHER switches, which would receive those events instead.
        var dragging = true
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                paintSwitch(under: next)
            case .leftMouseUp:
                dragging = false
            default:
                break
            }
        }
        VBSwitch.paintingValue = nil
    }

    /// Sets whichever switch is under the pointer to the value being painted.
    private func paintSwitch(under event: NSEvent) {
        guard let painting = VBSwitch.paintingValue,
              let contentView = window?.contentView else { return }

        let pointInWindow = event.locationInWindow
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        guard let hit = contentView.hitTest(pointInContent) else { return }

        // hitTest can land on a switch's internals rather than the switch itself.
        var candidate: NSView? = hit
        while let view = candidate, !(view is VBSwitch) {
            candidate = view.superview
        }
        guard let target = candidate as? VBSwitch, target.isEnabled, target.state != painting else {
            return
        }
        target.apply(painting)
    }

    /// Sets the state and notifies, the way a click would.
    private func apply(_ value: NSControl.StateValue) {
        state = value
        // `sendAction` rather than setting state silently: a switch changed by a
        // sweep must behave exactly like one changed by a click, or half the app's
        // state would update and the other half would not.
        sendAction(action, to: target)
    }
}
