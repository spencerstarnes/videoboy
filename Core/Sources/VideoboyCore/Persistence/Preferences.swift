//
//  Preferences.swift — what the app remembers between launches.
//
//  Purpose : A template (SPEC 16) describes one patch; this describes how the app
//            behaves regardless of which patch is loaded — where work is saved, what
//            a new source defaults to, which reminders have been dismissed, which
//            destinations exist. Kept apart from templates deliberately: loading
//            someone else's template must not move your save folder or re-enable the
//            dialogues you have already told the app to stop showing.
//  Inputs  : ~/Library/Application Support/Videoboy/preferences.json, or defaults
//            when it is absent, unreadable, or from a newer version.
//  Outputs : the same file, written atomically on every change.
//  Connects: the Preferences window (which edits it), the reminder prompts (which
//            ask it), output routing (which reads the destination list).
//  Extend  : add a property WITH a default value and decode it leniently, exactly as
//            templates do. A preferences file that fails to load because of a field
//            added later would silently reset someone's settings, which is worse
//            than ignoring the field.
//

import Foundation

/// How often the app saves the current template by itself.
public enum AutoSaveCadence: String, CaseIterable, Codable, Sendable {
    case never
    case everyFiveMinutes
    case everyFifteenMinutes
    case onQuitOnly

    public var displayName: String {
        switch self {
        case .never: "Never"
        case .everyFiveMinutes: "Every 5 minutes"
        case .everyFifteenMinutes: "Every 15 minutes"
        case .onQuitOnly: "On quit only"
        }
    }

    /// The interval in seconds, or nil when it is not a periodic cadence.
    public var interval: TimeInterval? {
        switch self {
        case .everyFiveMinutes: 300
        case .everyFifteenMinutes: 900
        case .never, .onQuitOnly: nil
        }
    }
}

/// A prompt that can be turned off permanently with "Don't remind me again".
///
/// A raw-value enum rather than free strings: a typo in a suppression key would
/// silently re-show a dialogue someone had dismissed, and that is the one bug this
/// feature exists to prevent.
public enum ReminderKind: String, CaseIterable, Codable, Sendable {
    /// On first launch, that no save location has been chosen.
    case setSaveLocation
    /// On launch, that nothing is being sent anywhere.
    case noOutputsSelected
    /// On quit, that there are unsaved changes.
    case saveOnQuit
    /// When a mapping is made while no MIDI device is connected.
    case midiWithNoDevice
    /// When an audio mapping is made while the clock is not running from audio.
    case audioMappingWithoutAudioClock

    public var displayName: String {
        switch self {
        case .setSaveLocation: "Choose a save location on first launch"
        case .noOutputsSelected: "Offer a default output when none is set"
        case .saveOnQuit: "Offer to save on quit"
        case .midiWithNoDevice: "Warn when mapping with no MIDI device"
        case .audioMappingWithoutAudioClock: "Warn when mapping audio with the clock elsewhere"
        }
    }
}

/// Everything the app remembers between launches.
public struct Preferences: Codable, Equatable, Sendable {

    // MARK: Save

    /// Where templates are saved by default. Nil until the person picks one.
    public var saveLocationPath: String?
    public var autoSave: AutoSaveCadence = .never

    // MARK: Defaults for new work

    public var defaultClockSource: String = "Internal"
    public var defaultSubdivision: String = "1/4"
    public var defaultTempo: Double = 120
    public var defaultLoopMode: LoopMode = .loop
    public var defaultBlendMode: BlendMode = .normal
    /// Whether a source starts playing as soon as it is loaded.
    public var playOnLoad: Bool = false

    // MARK: Reminders

    /// Which prompts have been answered with "don't remind me again".
    public var suppressedReminders: Set<ReminderKind> = []

    // MARK: Routing

    /// Destinations the output popovers offer, beyond the displays found at runtime.
    public var destinations: [OutputDestination] = []

    // MARK: Hot keys

    /// Action identifier to key equivalent, e.g. "cut.program" -> "return".
    public var hotKeys: [String: String] = [:]

    public init() {}

    /// The save location as a URL, or nil.
    public var saveLocation: URL? {
        get { saveLocationPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { saveLocationPath = newValue?.path }
    }

    /// Whether a prompt should still be shown.
    public func shouldRemind(_ kind: ReminderKind) -> Bool {
        !suppressedReminders.contains(kind)
    }

    // Decoding is lenient in both directions: a missing key takes the property's
    // default, and an unknown key is ignored by Codable already. Between them, a
    // preferences file written by any version of the app loads in any other.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        self.init()
        saveLocationPath = decode(.saveLocationPath, nil as String?)
        autoSave = decode(.autoSave, AutoSaveCadence.never)
        defaultClockSource = decode(.defaultClockSource, "Internal")
        defaultSubdivision = decode(.defaultSubdivision, "1/4")
        defaultTempo = decode(.defaultTempo, 120)
        defaultLoopMode = decode(.defaultLoopMode, LoopMode.loop)
        defaultBlendMode = decode(.defaultBlendMode, BlendMode.normal)
        playOnLoad = decode(.playOnLoad, false)
        suppressedReminders = decode(.suppressedReminders, Set<ReminderKind>())
        // Element by element, so one destination of a kind this build no longer has
        // does not take the whole list down with it. Capture cards were offered as
        // destinations once and are not any more — a card is an input.
        if let raw = try? container.decodeIfPresent(
            [FailableDestination].self, forKey: .destinations) {
            destinations = (raw ?? []).compactMap(\.value)
        }
        hotKeys = decode(.hotKeys, [String: String]())
    }
}

/// Decodes a destination, or nothing, without failing its neighbours.
private struct FailableDestination: Decodable {
    let value: OutputDestination?

    init(from decoder: Decoder) throws {
        value = try? OutputDestination(from: decoder)
    }
}

/// A place PROGRAM or a bus can be sent, as configured in preferences.
///
/// Displays are discovered at runtime and are NOT stored here — a display that was
/// unplugged should not linger in the list as a destination that cannot be reached.
/// This is only for the ones a person defines.
public struct OutputDestination: Codable, Equatable, Identifiable, Sendable {

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case obs
        case window
        case feedbackSend
        case ipStream
        case generator

        public var displayName: String {
            switch self {
            case .obs: "OBS"
            case .window: "Window"
            case .feedbackSend: "Feedback send"
            case .ipStream: "IP stream"
            case .generator: "Generator"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var name: String
    /// Kind-specific target: a host:port, a window title, a device name.
    public var target: String

    public init(id: String = UUID().uuidString, kind: Kind, name: String, target: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
    }
}

/// Loads, holds and saves `Preferences`.
///
/// A class rather than a value passed around: everything that reads preferences
/// needs to see a change made in the Preferences window immediately, and threading
/// a struct through every owner to achieve that is how settings end up stale in one
/// corner of an app.
public final class PreferenceStore {

    /// The current settings. Assigning saves them.
    public var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            save()
            onChange?(preferences)
        }
    }

    /// Called after any change, for live-updating what is on screen.
    public var onChange: ((Preferences) -> Void)?

    /// Where the file lives.
    public let fileURL: URL

    /// The standard location: ~/Library/Application Support/Videoboy/preferences.json.
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Videoboy", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.preferences = Self.load(from: self.fileURL)
    }

    /// Reads the file, falling back to defaults rather than failing.
    ///
    /// Losing settings is annoying; refusing to launch because settings are corrupt
    /// is worse. A bad file is logged and replaced on the next write.
    private static func load(from url: URL) -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.info(.app, "no preferences file at \(url.path); using defaults")
            return Preferences()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            Log.error(.app, "preferences at \(url.path) could not be read (\(error)); using defaults")
            return Preferences()
        }
    }

    /// Writes the file, creating the folder if needed.
    public func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.app, "could not save preferences to \(fileURL.path): \(error)")
        }
    }

    /// Whether a prompt should be shown.
    public func shouldRemind(_ kind: ReminderKind) -> Bool {
        preferences.shouldRemind(kind)
    }

    /// Records "don't remind me again" for a prompt.
    public func suppressReminder(_ kind: ReminderKind) {
        preferences.suppressedReminders.insert(kind)
        Log.info(.app, "reminder '\(kind.rawValue)' suppressed")
    }

    /// Brings every dismissed prompt back — the Defaults pane's reset.
    public func resetReminders() {
        preferences.suppressedReminders.removeAll()
        Log.info(.app, "all reminders restored")
    }
}
