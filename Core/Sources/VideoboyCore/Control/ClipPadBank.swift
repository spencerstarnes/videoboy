//
//  ClipPadBank.swift — the eight Clip Pads: what is on each, where it loads.
//
//  Purpose : The rules of the top bar's Clip Pads (docs/specs/clip-pads.md), kept
//            apart from the views so they are unit-tested: pads 1–4 load into the
//            left side's source (A or B, by its switch), 5–8 into the right side's
//            (C or D); pressing a pad whose clip is already the one in that source
//            restarts it rather than loading it again. Saved with the show.
//  Inputs  : pad assignments, the side switches, the file a source holds.
//  Outputs : the channel a pad loads into, and what a press should do.
//  Connects: the App's ClipPadController (which does the loading), TemplateDocument
//            (`clipPads`), ParamCode 6xJ/6xK (MIDI).
//  Extend  : a second bank would be a second `ClipPadBank`, not more pads in this one
//            — the number keys and the two switches assume eight.
//

import Foundation

/// One pad's clip.
public struct ClipPad: Codable, Equatable, Sendable {
    /// The clip's file (what the library knows it by, not an optimized copy).
    public var path: String
    /// The clip's in and out marks, 0...1, when trimmed.
    public var inPoint: Double?
    public var outPoint: Double?
    /// Armed on the beat (⌥⌘): fires at this rate. Nil when not armed.
    public var flipRate: PlaybackTiming?

    public init(path: String, inPoint: Double? = nil, outPoint: Double? = nil, flipRate: PlaybackTiming? = nil) {
        self.path = path
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.flipRate = flipRate
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The marked range, when there is one.
    public var range: ClosedRange<Double>? {
        guard inPoint != nil || outPoint != nil else { return nil }
        let low = inPoint ?? 0, high = outPoint ?? 1
        return low <= high ? low...high : nil
    }
}

/// The eight pads and the two side switches.
public struct ClipPadBank: Codable, Equatable, Sendable {

    public static let count = 8
    public static let perSide = 4

    /// Which half of the bar a pad is on.
    public enum Side: Sendable { case left, right }

    /// What pressing a pad does.
    public enum PressAction: Equatable, Sendable {
        /// Nothing on the pad.
        case empty
        /// Put the pad's clip into the channel.
        case load
        /// The clip is already the one in the channel: back to its head.
        case restart
    }

    /// Pads 1–8 (indices 0–7). Nil is empty.
    public var pads: [ClipPad?]
    /// Left side loads into B rather than A.
    public var leftTakesSecond: Bool
    /// Right side loads into D rather than C.
    public var rightTakesSecond: Bool

    public init() {
        pads = Array(repeating: nil, count: Self.count)
        leftTakesSecond = false
        rightTakesSecond = false
    }

    /// Which side a pad index (0–7) is on.
    public static func side(ofPad index: Int) -> Side {
        index < perSide ? .left : .right
    }

    /// The two channels a side can load into.
    public static func channels(for side: Side) -> (first: String, second: String) {
        side == .left ? ("A", "B") : ("C", "D")
    }

    /// The channel a side loads into now.
    public func channel(for side: Side) -> String {
        let pair = Self.channels(for: side)
        let second = side == .left ? leftTakesSecond : rightTakesSecond
        return second ? pair.second : pair.first
    }

    /// The channel a pad loads into now.
    public func channel(forPad index: Int) -> String {
        channel(for: Self.side(ofPad: index))
    }

    /// Sets which channel a side loads into. Returns false for a channel that side
    /// cannot reach (C on the left, say) and changes nothing.
    @discardableResult
    public mutating func setChannel(_ channel: String, for side: Side) -> Bool {
        let pair = Self.channels(for: side)
        guard channel == pair.first || channel == pair.second else { return false }
        if side == .left { leftTakesSecond = channel == pair.second } else { rightTakesSecond = channel == pair.second }
        return true
    }

    /// The pad on `index`, when there is one and the index is real.
    public subscript(pad index: Int) -> ClipPad? {
        get { pads.indices.contains(index) ? pads[index] : nil }
        set { if pads.indices.contains(index) { pads[index] = newValue } }
    }

    /// What a press on `index` does, given the file the pad's channel holds now.
    /// Same file (either form of its path) means restart — pressing again resets.
    public func pressAction(pad index: Int, channelHolds held: URL?) -> PressAction {
        guard let pad = self[pad: index] else { return .empty }
        guard let held else { return .load }
        return held.standardizedFileURL.path == pad.url.standardizedFileURL.path ? .restart : .load
    }

    /// Pad number (1–8) for the number key pressed, from its character; nil otherwise.
    public static func padIndex(forKey character: String) -> Int? {
        guard character.count == 1, let digit = Int(character), (1...count).contains(digit) else { return nil }
        return digit - 1
    }
}
