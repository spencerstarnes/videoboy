//
//  SystemAudioTap.swift — hear what the Mac is playing, without a loopback driver.
//
//  Purpose : Beat detection wants the music, and the music is usually coming out of
//            this Mac (Apple Music, Spotify, a browser, a DJ app), not into a
//            microphone. macOS 14.2 added Core Audio process taps, which hand an app
//            a copy of what other processes are playing — all of them ("System
//            Audio") or chosen ones (one app). Playback is untouched: the tap is a
//            copy, the speakers keep playing. No BlackHole, no Soundflower.
//  Inputs  : a `SystemAudioTap.Target`.
//  Outputs : mono float samples with the host time of their first sample, delivered
//            to a handler on a private queue.
//  Connects: AudioInput (which owns one of these when the audio source is not the
//            input device). `AudioAppCatalog` lists the apps that can be tapped.
//  Extend  : the recipe is Apple's ("Capturing system audio with Core Audio taps")
//            and Guilherme Rambo's AudioCap sample (BSD-2): describe the tap, create
//            it, wrap it in a private aggregate device, run an IO block on that
//            device. Undo in reverse order. Keep it that shape.
//
//  Permission: the first tap raises macOS's "System Audio Recording" prompt, worded
//  by NSAudioCaptureUsageDescription in Info.plist. Refused permission does not fail
//  here — the tap simply delivers silence — which is why the beat tracker has a
//  `silent` state and the toolbar says NO SIGNAL rather than pretending to listen.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore
import VideoboyCore

/// Reads a fixed-size Core Audio property. Nil on any error; callers decide whether
/// a missing property is worth a log line.
private func audioProperty<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
    qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0
) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    let status = AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, pointer)
    guard status == noErr else { return nil }
    return pointer.move()
}

/// Reads a CFString Core Audio property.
private func audioStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

/// Every process Core Audio knows about, as audio object IDs.
private func audioProcessObjects() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
        return []
    }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
        return []
    }
    return objects
}

// MARK: - Which apps can be listened to

/// An app that has an audio presence, for the clock menu.
struct AudioApp: Equatable {
    let bundleID: String
    let name: String
    /// True when any of its processes is producing output right now.
    let isPlaying: Bool
}

/// Lists the running apps that can be tapped, and finds their audio processes.
enum AudioAppCatalog {

    /// A running app and all the Core Audio process objects that belong to it.
    ///
    /// "Belong" is looser than "is": browsers play media from helper processes.
    /// Safari's audio comes out of `com.apple.WebKit.GPU`, which macOS names "Safari
    /// Graphics and Media"; Chrome's out of "Google Chrome Helper". So a process
    /// belongs to an app when its bundle ID extends the app's, or its display name
    /// starts with the app's name. Checked against the live process list on macOS 15.
    private static func processObjects(
        for app: NSRunningApplication
    ) -> (objects: [AudioObjectID], isPlaying: Bool) {
        guard let bundleID = app.bundleIdentifier else { return ([], false) }
        let appName = app.localizedName ?? ""
        var objects: [AudioObjectID] = []
        var isPlaying = false
        for object in audioProcessObjects() {
            let processBundle = audioStringProperty(object, kAudioProcessPropertyBundleID) ?? ""
            let pid = audioProperty(object, kAudioProcessPropertyPID, as: pid_t.self) ?? -1
            let processName = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "" : ""
            let belongs = processBundle == bundleID
                || processBundle.hasPrefix(bundleID + ".")
                || pid == app.processIdentifier
                || (!appName.isEmpty && processName.hasPrefix(appName + " "))
            guard belongs else { continue }
            objects.append(object)
            if (audioProperty(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0 {
                isPlaying = true
            }
        }
        return (objects, isPlaying)
    }

    /// Ordinary apps (the kind with a Dock icon) that have at least one audio process,
    /// playing ones first. Videoboy itself is left out — tapping yourself is a loop.
    static func apps() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [AudioApp] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            guard let bundleID = app.bundleIdentifier else { continue }
            let found = processObjects(for: app)
            guard !found.objects.isEmpty else { continue }
            result.append(AudioApp(
                bundleID: bundleID, name: app.localizedName ?? bundleID, isPlaying: found.isPlaying))
        }
        return result.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The audio process objects for an app by bundle ID, or empty if it is not running.
    static func processObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return []
        }
        return processObjects(for: app).objects
    }

    /// Videoboy's own audio process object, to exclude from a system-wide tap.
    static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        let object = withUnsafePointer(to: &pid) { pointer in
            audioProperty(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyTranslatePIDToProcessObject, as: AudioObjectID.self,
                qualifier: pointer, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
        }
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }
}

// MARK: - The tap

/// A running Core Audio process tap.
@available(macOS 14.2, *)
final class SystemAudioTap {

    enum Target: Equatable {
        /// Everything the Mac plays, except Videoboy.
        case system
        /// Only these process objects.
        case processes([AudioObjectID])
    }

    /// Why a tap could not start, worded for the notice the app shows.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Called per IO cycle with mono samples, the sample rate, and the host time
    /// (seconds, same clock as CACurrentMediaTime) of the first sample.
    typealias Handler = (_ samples: [Float], _ sampleRate: Double, _ hostTime: Double) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "videoboy.audio.tap", qos: .userInitiated)

    deinit { stop() }

    /// Creates the tap and starts delivering samples.
    func start(_ target: Target, handler: @escaping Handler) throws {
        stop()

        let description: CATapDescription
        switch target {
        case .system:
            let exclude = AudioAppCatalog.ownProcessObject().map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        case .processes(let objects):
            guard !objects.isEmpty else {
                throw Failure(description: "That app has no audio to listen to right now. Start playback in it, or choose System Audio.")
            }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "Videoboy beat detection"
        // Private: the tap and its device are invisible to other apps and vanish
        // with this process. Unmuted: the performer still hears the music.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else {
            throw Failure(description: "macOS refused to create an audio tap (error \(status)).")
        }
        tapID = newTap

        guard let format = audioProperty(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            stop()
            throw Failure(description: "The audio tap reported no usable format.")
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            stop()
            throw Failure(description: "The audio tap delivers a format Videoboy does not read (\(format.mFormatID)).")
        }

        // The aggregate device the tap is read through. It needs no real sub-device
        // for input-only use; the tap list is what gives it a stream.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Videoboy Beat Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else {
            stop()
            throw Failure(description: "Could not create the audio device for the tap (error \(status)).")
        }
        aggregateID = newAggregate

        let sampleRate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, let firstData = first.mData else { return }

            // Mix to mono, interleaved or not.
            var mono: [Float]
            if interleaved {
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let samples = firstData.assumingMemoryBound(to: Float.self)
                mono = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                mono = [Float](repeating: 0, count: frames)
                var used = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                        mono[frame] += samples[frame]
                    }
                    used += 1
                }
                if used > 1 { for frame in 0..<frames { mono[frame] /= Float(used) } }
            }
            guard !mono.isEmpty else { return }

            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
                : CACurrentMediaTime()
            handler(mono, sampleRate, hostTime)
        }
        guard status == noErr, ioProcID != nil else {
            stop()
            throw Failure(description: "Could not attach to the audio tap (error \(status)).")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw Failure(description: "The audio tap would not start (error \(status)).")
        }
        Log.info(.clock, "system audio tap running at \(Int(sampleRate)) Hz, \(channels) ch (\(target == .system ? "all apps" : "selected app"))")
    }

    /// Stops and tears down, in reverse order of creation. Safe to call twice.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
