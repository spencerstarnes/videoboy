//
//  DetectSession.swift — hold Shift to see what is mappable, click to map it.
//
//  Purpose : MIDI learn has worked in Core since Phase 2, but reaching it meant
//            finding a parameter's M badge and picking "Learn" from a menu. That is
//            fine for an effect parameter you are configuring at leisure and wrong
//            for the question a performer actually asks, which is "what on this
//            window can I put under my hands?". Holding Shift answers it: every
//            mappable control lights at once, and clicking one arms it (SPEC 7).
//  Inputs  : Shift key state, via a local event monitor.
//  Outputs : highlight state on every VBFader that carries a slot and a param code;
//            a detect request when one is Shift-clicked.
//  Connects: ShellController (which owns the engine and answers the request),
//            VBFader (which draws the highlight and reports the click).
//  Extend  : to make a NEW kind of control mappable, give it `mappingSlot` and
//            `mappingCode` and teach `apply(to:)` to recognise it. Do not add a
//            second highlight mechanism — the point is that one gesture reveals
//            everything, and that only holds if everything answers to it.
//

import AppKit
import VideoboyCore

/// Watches the Shift key and lights up every mappable control beneath a root view.
final class DetectSession {

    /// Called when a mappable control is Shift-clicked.
    /// Called when a control is shift-clicked: its slot, its code, and WHAT KIND of
    /// control it is.
    ///
    /// The kind matters because a button should learn a button. On a controller that is
    /// streaming — a knob being nudged, an LFO on a CC — the first message to arrive is
    /// very often not the one you meant, and without the filter, learning a pad is a
    /// coin toss against every knob on the surface.
    var onDetectRequested: ((String, ParamCode, MIDIInput.DetectFilter) -> Void)?

    /// Called when the Shift state changes, so the toolbar can show it is armed.
    var onArmedChanged: ((Bool) -> Void)?

    /// True while Shift is held.
    private(set) var isArmed = false

    private weak var root: NSView?
    private var monitor: Any?

    init(root: NSView) {
        self.root = root
        // A local monitor rather than `flagsChanged` on a view: the performer should
        // not have to click the right thing first to make Shift mean something.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setArmed(event.modifierFlags.contains(.shift))
            // The same monitor also drives the sweep-arming highlight, so the two
            // modal hints cannot disagree about whether a key is down.
            self?.setSweepArming(
                event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option))
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Re-applies the current state, for controls built after the key went down.
    func refresh() {
        guard let root else { return }
        apply(to: root)
    }

    /// Arms or disarms without a key press, for the self-QA render.
    ///
    /// Not a back door: "armed" is a real state of this object and the Shift key is
    /// only one way into it. The alternative is for the check to set the highlights
    /// itself, which would prove the highlights can be drawn and nothing about
    /// whether this class ever reaches them.
    func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        refresh()
        onArmedChanged?(armed)
    }

    /// Whether the mark-a-sweep gesture is being held.
    private(set) var isSweepArming = false

    /// Lights every fader that could take a sweep mark. Exposed for the same reason
    /// `setArmed` is: a check proving the highlight reaches real controls has to be
    /// able to turn it on without synthesising a modifier key.
    func setSweepArming(_ arming: Bool) {
        guard arming != isSweepArming else { return }
        isSweepArming = arming
        refresh()
    }

    /// Walks the tree rather than keeping a register of controls.
    ///
    /// Panels rebuild their rows as effects are added, reordered and bypassed, so a
    /// register would go stale in exactly the situations where being wrong is most
    /// annoying. The tree is a few hundred views and this runs on a key press, not
    /// per frame.
    private func apply(to view: NSView) {
        if let fader = view as? VBFader {
            let mappable = fader.mappingSlot != nil && fader.mappingCode != nil
            fader.isDetectHighlighted = isArmed && mappable
            fader.isSweepArming = isSweepArming && mappable
            if mappable && fader.onDetectRequested == nil {
                fader.onDetectRequested = { [weak self] slot, code in
                    // A fader takes anything: a knob, a fader, even a pad used as a
                    // two-position switch.
                    self?.onDetectRequested?(slot, code, .anything)
                }
            }
        }

        // Action keys — CUT, FADE — light up too. They are momentary rather than
        // continuous, but "which control does this MIDI button drive" is the same
        // question for both, and a performer holding Shift should see everything that
        // can be learned, not only the things that happen to be faders.
        if let key = view as? VBOptionButton {
            let mappable = key.mappingSlot != nil && key.mappingCode != nil
            key.isDetectHighlighted = isArmed && mappable
            // Only CUT/FADE/BEAT answer to ⌘⌥ — `onFlipRateChanged` is set solely by
            // `wireButtonTapRate`, so a plain toggle like AUTO or Safe never pulses
            // for a gesture it has no rate key to show.
            key.isSweepArming = isSweepArming && key.onFlipRateChanged != nil
            if mappable && key.onDetectRequested == nil {
                key.onDetectRequested = { [weak self] slot, code in
                    // A key learns a KEY. Notes only.
                    self?.onDetectRequested?(slot, code, .notesOnly)
                }
            }
        }
        // Bus keys — A, B, C, D — the same idea. They are square lamps, not faders,
        // and a performer reaching for a physical button to cut straight to a source
        // wants exactly the same button here, never a knob or a fader brushed on the
        // way to it.
        if let bus = view as? VBBusButton {
            let mappable = bus.mappingSlot != nil && bus.mappingCode != nil
            bus.isDetectHighlighted = isArmed && mappable
            if mappable && bus.onDetectRequested == nil {
                bus.onDetectRequested = { [weak self] slot, code in
                    self?.onDetectRequested?(slot, code, .notesOnly)
                }
            }
        }
        // Menus, switches and colour wells. They became mappable when the EMU panel
        // stopped using a fader for everything: a knob on a menu steps through its
        // items, and a pad on a switch is exactly what a pad is for.
        if let mappable = view as? MappableControl {
            mappable.isDetectHighlighted = isArmed
            if mappable.onDetectRequested == nil {
                mappable.onDetectRequested = { [weak self] slot, code, filter in
                    self?.onDetectRequested?(slot, code, filter)
                }
            }
        }

        for subview in view.subviews { apply(to: subview) }
    }
}
