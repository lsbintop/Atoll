/*
 * Atoll (DynamicIsland)
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Atoll Contributors
 *
 * CoreAudio tap for capturing real-time audio from music applications.
 * Uses macOS 14.2+ Process Tap API for efficient audio capture.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import AudioToolbox
import CoreAudio
import Defaults
import simd
import os.log

private let audioTapLog = OSLog(subsystem: "com.atoll.dynamicisland", category: "AudioTap")

// CoreAudio fires this on a high-priority background real-time thread.
let audioIOProc: AudioDeviceIOProc = {
    inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData in

    guard let clientData = clientData else { return noErr }
    let scanner = Unmanaged<AudioTap>.fromOpaque(clientData).takeUnretainedValue()

    if scanner.isPaused { return noErr }

    let mutableInputData = UnsafeMutablePointer(mutating: inInputData)
    let bufferList = UnsafeMutableAudioBufferListPointer(mutableInputData)

    if let firstBuffer = bufferList.first, let data = firstBuffer.mData {
        // CoreAudio gives us byte size, divide by 4 (Float size) to get array length
        let floatCount = Int32(firstBuffer.mDataByteSize) / Int32(MemoryLayout<Float>.size)

        let floatData = data.assumingMemoryBound(to: Float.self)

        // Pass the mono array directly to C++
        scanner.bridge.processBuffer(floatData, count: floatCount)
    }

    return noErr
}

private func getAudioObjectID(for pid: pid_t) -> AudioObjectID? {
    var audioObjectID: AudioObjectID = kAudioObjectUnknown
    var pidValue = pid

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

    // We query the global system object (kAudioObjectSystemObject)
    // We pass the PID as the "qualifier", and it returns the AudioObjectID
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        qualifierSize,
        &pidValue,
        &size,
        &audioObjectID
    )

    if status == noErr && audioObjectID != kAudioObjectUnknown {
        return audioObjectID
    }

    return nil
}

/// Singleton class for real-time audio capture from music apps
class AudioTap: NSObject {
    static let shared = AudioTap()
    
    let bridge = AudioBridge()
    var isPaused: Bool = false
    private var displayMagnitudes: [Float] = Array(repeating: 0, count: 6)

    // CoreAudio stuff
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var captureIsRunning = false
    private var updateTimer: Timer?
    
    // Serial queue to prevent race conditions
    private let audioQueue = DispatchQueue(label: "com.atoll.audiotap", qos: .userInitiated)
    
    // Debounce restart requests
    private var pendingRestartWorkItem: DispatchWorkItem?

    private let targetBundleIDs = [
        "com.apple.Music",
        "com.spotify.client",
        "com.amazon.music",
        "sh.cider.genten.mac",
        "com.apple.Safari",
        "com.tidal.desktop",
        "tv.plex.plexamp",
        "com.roon.Roon",
        "com.audirvana.Audirvana-Studio",
        "com.vox.vox",
        "com.coppertino.Vox",
    ]

    private override init() {
        super.init()
    }

    @objc private func updateSmoothedMagnitudes() {
        let nsMagnitudes = bridge.getSmoothedMagnitudes()
        let targetLevels = nsMagnitudes.map { $0.floatValue }
        
        let smoothingFactor: Float = 0.4
        
        for i in 0..<min(targetLevels.count, displayMagnitudes.count) {
            let difference = targetLevels[i] - displayMagnitudes[i]
            displayMagnitudes[i] += difference * smoothingFactor
        }
    }

    func getSmoothedMagnitudes() -> [Float] {
        return displayMagnitudes
    }

    func startCapture() async {
        await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                self?.startCaptureSync()
                continuation.resume()
            }
        }
    }
    
    private func startCaptureSync() {
        guard !captureIsRunning else { return }

        let runningApps = NSWorkspace.shared.runningApplications
        var targetPIDs: [AudioDeviceID] = []

        // AirPods/Bluetooth output + Spotify don't mix: process-tapping Spotify into our
        // private aggregate device disturbs the system Now Playing / AVRCP session, so the
        // AirPods pause gesture finds no target and macOS falls back to Siri. Spotify is
        // controlled via AppleScript and registers weakly with MediaRemote, which is why
        // only it is affected (Apple Music etc. stay registered). While a Bluetooth route is
        // active, skip tapping Spotify to preserve media control — the visualizer stays live
        // for Spotify on wired/built-in output and for every other app on any output.
        let bluetoothOutputActive = AudioRouteManager.shared.isDefaultOutputBluetooth()

        if Defaults[.mediaController] == .daoliYu {
            let processID = ProcessInfo.processInfo.processIdentifier
            if let deviceID = getAudioObjectID(for: processID) {
                targetPIDs.append(deviceID)
            }
        } else {
            for app in runningApps {
                guard let bundleID = app.bundleIdentifier,
                      targetBundleIDs.contains(bundleID) else {
                    continue
                }
                if bundleID == SpotifyController.bundleIdentifier, bluetoothOutputActive {
                    continue
                }
                if let deviceID = getAudioObjectID(for: app.processIdentifier) {
                    targetPIDs.append(deviceID)
                }
            }
        }

        guard !targetPIDs.isEmpty else { return }

        let description = CATapDescription()
        description.processes = targetPIDs
        description.isMixdown = true
        description.isMono = true
        
        tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            os_log(.error, log: audioTapLog, "Process tap creation failed: %{public}d (%{public}@)", status, fourCharCodeToString(status))
            return
        }

        // Get the tap's unique hardware UID
        var tapUID: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.stride)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = withUnsafeMutablePointer(to: &tapUID) { uidPtr in
            AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &propertySize, uidPtr)
        }
        guard status == noErr else {
            os_log(.error, log: audioTapLog, "Tap UID lookup failed: %{public}d (%{public}@)", status, fourCharCodeToString(status))
            cleanupPartialSetup()
            return
        }

        // Create the Aggregate Device (a "virtual microphone" that we can route the tap into)
        let tapList = [[kAudioSubTapUIDKey: tapUID]]
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atoll_Virtual_Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,  // Hides it from the user's sound settings
            kAudioAggregateDeviceTapListKey: tapList,
        ]

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDict as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            os_log(.error, log: audioTapLog, "Aggregate device creation failed: %{public}d (%{public}@)", status, fourCharCodeToString(status))
            cleanupPartialSetup()
            return
        }

        // Bind the Callback to the device
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(aggregateDeviceID, audioIOProc, selfPointer, &ioProcID)

        guard status == noErr, let validIOProcID = ioProcID else {
            os_log(.error, log: audioTapLog, "IOProc creation failed: %{public}d (%{public}@)", status, fourCharCodeToString(status))
            cleanupPartialSetup()
            return
        }

        // Start listening
        status = AudioDeviceStart(aggregateDeviceID, validIOProcID)
        guard status == noErr else {
            os_log(.error, log: audioTapLog, "Audio capture start failed: %{public}d (%{public}@)", status, fourCharCodeToString(status))
            cleanupPartialSetup()
            return
        }

        captureIsRunning = true
        
        DispatchQueue.main.async { [weak self] in
            self?.updateTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60.0, target: self as Any, selector: #selector(self?.updateSmoothedMagnitudes), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self?.updateTimer = timer
        }
    }
    
    private func cleanupPartialSetup() {
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        
        DispatchQueue.main.async { [weak self] in
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
        }
    }

    func restartCapture() {
        // Cancel any pending restart
        pendingRestartWorkItem?.cancel()
        
        // Debounce: wait 500ms before actually restarting
        let workItem = DispatchWorkItem { [weak self] in
            self?.audioQueue.async {
                self?.stopCaptureSync()
                // Small delay to let CoreAudio fully release resources
                Thread.sleep(forTimeInterval: 0.1)
                // Re-read the setting instead of trusting the state at scheduling time: the
                // waveform can be switched off during the debounce window, and a stale
                // restart must not bring capture back up behind the user's back.
                guard Defaults[.enableRealTimeWaveform] else { return }
                self?.startCaptureSync()
            }
        }
        pendingRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func stopCapture() {
        // Drop a queued restart first, otherwise a debounced route/app change can resurrect
        // capture right after the caller asked us to stop.
        pendingRestartWorkItem?.cancel()
        pendingRestartWorkItem = nil

        audioQueue.sync { [weak self] in
            self?.stopCaptureSync()
        }
    }
    
    private func stopCaptureSync() {
        guard captureIsRunning else { return }

        // Stop listening
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, validIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }

        // Destroy resources
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        captureIsRunning = false
        
        DispatchQueue.main.async { [weak self] in
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
            // Reset display magnitudes safely on main thread
            self?.displayMagnitudes = Array(repeating: 0, count: 6)
        }
    }
    
    var isCapturing: Bool {
        captureIsRunning
    }

    deinit {
        stopCaptureSync()
    }
}

// Helper to convert OSStatus to readable string
private func fourCharCodeToString(_ code: OSStatus) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    return String(code)
}
