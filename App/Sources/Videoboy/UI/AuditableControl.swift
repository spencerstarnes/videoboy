//
//  AuditableControl.swift — how a closure-driven control reports that it is wired.
//
//  Purpose : The control audit decides whether a control does anything by looking
//            for a target and an action. That works for AppKit's own controls and is
//            blind to the custom ones here, which carry closures instead — and a nil
//            closure is exactly the failure that shipped once already, a row of ✕
//            buttons that looked live and did nothing. A closure cannot be inspected
//            from outside, so the control has to answer for itself.
//  Inputs  : none.
//  Outputs : whether clicking this control would reach anything.
//  Connects: ControlAuditSelfQA (which asks), and every custom control that is
//            driven by a closure rather than by target/action.
//  Extend  : a new closure-driven control conforms and returns whether its closure
//            is set. Do NOT return a constant true to quiet the audit — that throws
//            away the only check that catches an unwired control before a show does.
//

import AppKit

/// A control that knows whether it is connected to anything.
protocol AuditableControl: AnyObject {
    /// True when activating this control would actually reach something.
    var isWiredForAudit: Bool { get }
}
