//
//  UndoHistory.swift — what ⌘Z takes back, and File ▸ Undo History lists.
//
//  Purpose : A list of the edits a person made by hand, each one a set of parameter
//            values before and after, so any of them can be taken back or put back
//            again. A drag is ONE step, not sixty: changes to the same control that
//            arrive close together are folded into the step already open.
//  Inputs  : `record(...)` from the UI's edit paths — never from MIDI, LFOs, sweeps,
//            automation or an undo being applied, which are not edits someone would
//            expect ⌘Z to reverse.
//  Outputs : values handed to `apply`, which writes them to the ParamRegistry.
//  Connects: ShellController (records and applies), the File and Edit menus (which
//            read `steps`, `position`, `canUndo`, `canRedo`), Preferences.undoLimit.
//  Extend  : a step is values only. An edit that is not expressible as parameter
//            values (adding, removing or reordering an effect) needs its own change
//            kind here, with a test, before it can be recorded.
//
//  Nothing here runs on the frame path. Recording is a few array operations on the
//  main thread, once per control event.
//

import Foundation

/// One parameter, before and after an edit.
public struct ParameterChange: Equatable, Sendable {
    public let slot: String
    public let code: ParamCode
    public var before: Double
    public var after: Double

    public init(slot: String, code: ParamCode, before: Double, after: Double) {
        self.slot = slot
        self.code = code
        self.before = before
        self.after = after
    }
}

/// One entry in the history: what the person did, named the way the menu shows it.
public struct UndoStep: Equatable, Sendable {
    /// "Wet/Dry", "Blend Mode", "AVE-5 Position" — the menu reads "Undo <name>".
    public let name: String
    /// When the step was last added to (a drag keeps it open until it stops).
    public internal(set) var date: Date
    public internal(set) var changes: [ParameterChange]

    /// Which controls the step touches, for deciding whether the next edit folds in.
    var keys: Set<String> { Set(changes.map { "\($0.slot)|\($0.code.rawValue)" }) }
}

/// The edit history, oldest first.
///
/// `position` counts the steps currently applied: everything before it can be undone,
/// everything from it on can be redone. A new edit throws the redo side away, as every
/// Mac app does.
public final class UndoHistory {

    /// How close together two changes to the same control must be to count as one
    /// gesture. Long enough to hold a fader drag or a knob twist together, short
    /// enough that two deliberate moves stay two steps.
    public static let coalesceWindow: TimeInterval = 0.6

    /// The range a person can set the limit to in Settings.
    public static let limitRange: ClosedRange<Int> = 10...1000
    public static let defaultLimit = 100

    public private(set) var steps: [UndoStep] = []
    public private(set) var position = 0

    /// The most steps kept. Lowering it drops the oldest straight away.
    public var limit: Int {
        didSet {
            limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
            trim()
        }
    }

    /// Writes a value back. Set by the owner; the history never touches the registry.
    public var apply: ((_ slot: String, _ code: ParamCode, _ value: Double) -> Void)?
    /// Called after anything changes, so menus and readouts can refresh.
    public var onChange: (() -> Void)?

    /// Whether the newest step may still be added to. Closed by undo, redo and revert,
    /// so a drag right after ⌘Z starts a step of its own.
    private var lastStepIsOpen = false

    public init(limit: Int = UndoHistory.defaultLimit) {
        self.limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
    }

    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < steps.count }
    public var nextUndo: UndoStep? { canUndo ? steps[position - 1] : nil }
    public var nextRedo: UndoStep? { canRedo ? steps[position] : nil }

    /// Records an edit that has ALREADY been made. Changes whose before and after are
    /// equal are dropped; an edit with nothing left is not recorded.
    ///
    /// - Parameter now: injectable for tests.
    public func record(_ name: String, changes: [ParameterChange], now: Date = Date()) {
        let real = changes.filter { $0.before != $0.after && $0.before.isFinite && $0.after.isFinite }
        guard !real.isEmpty else { return }

        // The same control, still moving: extend the open step rather than add one.
        if lastStepIsOpen, position == steps.count, var last = steps.last, last.name == name,
           now.timeIntervalSince(last.date) <= Self.coalesceWindow,
           Set(real.map { "\($0.slot)|\($0.code.rawValue)" }).isSubset(of: last.keys) {
            for change in real {
                if let index = last.changes.firstIndex(where: { $0.slot == change.slot && $0.code == change.code }) {
                    last.changes[index].after = change.after
                }
            }
            // A drag that came back to where it started is not an edit any more.
            last.changes.removeAll { $0.before == $0.after }
            last.date = now
            if last.changes.isEmpty {
                steps.removeLast()
                position = steps.count
                lastStepIsOpen = false
            } else {
                steps[steps.count - 1] = last
            }
            onChange?()
            return
        }

        if position < steps.count { steps.removeSubrange(position...) }
        steps.append(UndoStep(name: name, date: now, changes: real))
        position = steps.count
        lastStepIsOpen = true
        trim()
        onChange?()
    }

    /// Takes back the newest applied step. Returns its name, or nil if there was none.
    @discardableResult
    public func undo() -> String? {
        guard canUndo else { return nil }
        position -= 1
        let step = steps[position]
        // Reverse order: a step that changed one control twice ends on the first value.
        for change in step.changes.reversed() { apply?(change.slot, change.code, change.before) }
        lastStepIsOpen = false
        onChange?()
        return step.name
    }

    /// Puts back the next undone step. Returns its name, or nil if there was none.
    @discardableResult
    public func redo() -> String? {
        guard canRedo else { return nil }
        let step = steps[position]
        for change in step.changes { apply?(change.slot, change.code, change.after) }
        position += 1
        lastStepIsOpen = false
        onChange?()
        return step.name
    }

    /// Undoes or redoes until exactly `target` steps are applied (0 is "as opened").
    public func revert(to target: Int) {
        let target = min(max(target, 0), steps.count)
        let saved = onChange
        onChange = nil
        while position > target { undo() }
        while position < target { redo() }
        onChange = saved
        onChange?()
    }

    /// Forgets everything — a template load replaces every value the steps refer to.
    public func clear() {
        steps.removeAll()
        position = 0
        lastStepIsOpen = false
        onChange?()
    }

    /// Drops the oldest steps beyond the limit. The redo side is kept in the count:
    /// the limit is how many steps the menu can hold, whichever side they are on.
    private func trim() {
        let excess = steps.count - limit
        guard excess > 0 else { return }
        steps.removeFirst(excess)
        position = max(position - excess, 0)
    }
}
