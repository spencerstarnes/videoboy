//
//  DeviceConfig.swift — reads config/devices.json.
//
//  Purpose : Device identity (which display is the HDMI card, which capture device is
//            the DVC100) is machine-specific and must never be hardcoded in source.
//            This is the only place that file is parsed.
//  Inputs  : config/devices.json, matching config/devices.example.json in shape.
//  Outputs : a `DeviceConfig`, or defaults if the file is absent.
//  Connects: the Display Router (output window placement) and the loopback capture
//            check (which device to open).
//  Extend  : add a field here and to config/devices.example.json together. Missing
//            fields must keep a sensible default — a partial file is not an error.
//

import Foundation

/// The target video mode for an output, as requested in config.
/// What is actually negotiated is logged separately (SPEC 3).
public struct TargetMode: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var interlaced: Bool

    public init(width: Int, height: Int, fps: Double, interlaced: Bool) {
        self.width = width
        self.height = height
        self.fps = fps
        self.interlaced = interlaced
    }

    /// Standard-definition default from SPEC 3: 720x480, 29.97, interlaced.
    public static let standardDefinition = TargetMode(
        width: StandardDefinition.width,
        height: StandardDefinition.height,
        fps: StandardDefinition.frameRate,
        interlaced: true
    )

    /// The short form shown in the Display Router and recorded in metrics.json.
    public var description: String {
        let rate = String(format: "%.2f", fps)
        return "\(width)x\(height)@\(rate)\(interlaced ? "i" : "p")"
    }
}

/// Which display to send program output to.
public struct OutputDisplayConfig: Codable {
    /// Substring matched against `NSScreen` names.
    public var name: String
    /// Used when no name matches; index into the active display list.
    public var fallbackIndex: Int
    public var targetMode: TargetMode

    private enum CodingKeys: String, CodingKey {
        case name
        case fallbackIndex = "fallback_index"
        case targetMode = "target_mode"
    }
}

/// Which capture device closes the loopback.
public struct LoopbackCaptureConfig: Codable {
    /// Substring matched against capture device names.
    public var name: String
    public var expectedFormat: ExpectedFormat

    public struct ExpectedFormat: Codable {
        public var width: Int
        public var height: Int
        public var fps: Double
        public var standard: String
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case expectedFormat = "expected_format"
    }
}

/// The whole of config/devices.json.
public struct DeviceConfig: Codable {
    public var outputDisplay: OutputDisplayConfig?
    public var loopbackCapture: LoopbackCaptureConfig?
    public var samplesDir: String?
    public var selfqaOut: String?

    private enum CodingKeys: String, CodingKey {
        case outputDisplay = "output_display"
        case loopbackCapture = "loopback_capture"
        case samplesDir = "samples_dir"
        case selfqaOut = "selfqa_out"
    }

    /// Loads config/devices.json from the repo, or returns an empty config.
    ///
    /// A missing or malformed file is logged and degraded, never fatal: the app must
    /// still launch on a machine that has never been configured, with the Display
    /// Router simply showing no preferred device.
    public static func load(from url: URL? = nil) -> DeviceConfig {
        let path = url ?? RepoPaths.config.appendingPathComponent("devices.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            Log.warn(.output, "config/devices.json not found; using defaults (no preferred display or capture device)")
            return DeviceConfig(outputDisplay: nil, loopbackCapture: nil, samplesDir: nil, selfqaOut: nil)
        }
        do {
            let data = try Data(contentsOf: path)
            let config = try JSONDecoder().decode(DeviceConfig.self, from: data)
            Log.info(.output, "loaded device config: display='\(config.outputDisplay?.name ?? "-")' capture='\(config.loopbackCapture?.name ?? "-")'")
            return config
        } catch {
            Log.error(.output, "config/devices.json could not be read (\(error)); using defaults")
            return DeviceConfig(outputDisplay: nil, loopbackCapture: nil, samplesDir: nil, selfqaOut: nil)
        }
    }

    /// The requested output mode, or the standard-definition default.
    public var requestedMode: TargetMode { outputDisplay?.targetMode ?? .standardDefinition }
}
