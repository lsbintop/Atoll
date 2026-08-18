# DaoliYu Real-Time Waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the real-time visualizer reflect only DaoliYu audio while DaoliYu is the selected media controller.

**Architecture:** Reuse the existing Core Audio process tap. Select Atoll's own audio process object in DaoliYu mode, retain external-player discovery in other modes, and rebuild the tap whenever the selected media controller changes.

**Tech Stack:** Swift, SwiftUI, Defaults, Core Audio `CATapDescription`, AppKit

---

### Task 1: Route DaoliYu Through the Real-Time Visualizer

**Files:**
- Modify: `DynamicIsland/audio/AudioVisualizerView.swift`

- [ ] **Step 1: Remove the controller-specific simulated fallback**

Replace the visualizer condition with:

```swift
if enableRealTimeWaveform {
    RealTimeAudioSpectrumView(isPlaying: $isPlaying)
} else {
    AudioSpectrumView(isPlaying: $isPlaying)
}
```

Remove the unused `@Default(.mediaController)` property.

- [ ] **Step 2: Parse the modified file**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/audio/AudioVisualizerView.swift
```

Expected: exit code 0.

### Task 2: Capture Only Atoll Audio in DaoliYu Mode

**Files:**
- Modify: `DynamicIsland/audio/AudioTap.swift`

- [ ] **Step 1: Select the process source from the active controller**

In `startCaptureSync()`, replace unconditional external-app discovery with:

```swift
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
        if bundleID == SpotifyController.bundleIdentifier,
           bluetoothOutputActive {
            continue
        }
        if let deviceID = getAudioObjectID(for: app.processIdentifier) {
            targetPIDs.append(deviceID)
        }
    }
}
```

This makes `CATapDescription.processes` contain only Atoll's process object in
DaoliYu mode, so external players cannot affect the waveform.

- [ ] **Step 2: Parse the modified file**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/audio/AudioTap.swift
```

Expected: exit code 0.

### Task 3: Rebuild the Tap When Media Controller Changes

**Files:**
- Modify: `DynamicIsland/DynamicIslandApp.swift`

- [ ] **Step 1: Avoid irrelevant external-app restarts in DaoliYu mode**

Add `Defaults[.mediaController] != .daoliYu` to the real-time waveform guards
inside the application launch and termination observers.

- [ ] **Step 2: Observe the media controller default**

After the real-time waveform preference subscription, add:

```swift
Defaults.publisher(.mediaController, options: [])
    .sink { change in
        guard change.oldValue != change.newValue,
              Defaults[.enableRealTimeWaveform] else {
            return
        }
        AudioTap.shared.restartCapture()
    }
    .store(in: &cancellables)
```

- [ ] **Step 3: Retry capture when DaoliYu starts playing**

Subscribe to `DaoliYuManager.shared.audioEngine.$isPlaying`, remove duplicate
values, and restart `AudioTap` when playback becomes active while DaoliYu and
the real-time waveform setting are selected.

- [ ] **Step 4: Parse all modified source files**

Run:

```bash
xcrun swiftc -frontend -parse \
  DynamicIsland/audio/AudioVisualizerView.swift \
  DynamicIsland/audio/AudioTap.swift \
  DynamicIsland/DynamicIslandApp.swift
```

Expected: exit code 0.

### Task 4: Verify Build and Runtime Routing

**Files:**
- Verify: `DynamicIsland/audio/AudioVisualizerView.swift`
- Verify: `DynamicIsland/audio/AudioTap.swift`
- Verify: `DynamicIsland/DynamicIslandApp.swift`

- [ ] **Step 1: Check formatting and accidental changes**

Run:

```bash
git diff --check -- \
  DynamicIsland/audio/AudioVisualizerView.swift \
  DynamicIsland/audio/AudioTap.swift \
  DynamicIsland/DynamicIslandApp.swift
```

Expected: no output.

- [ ] **Step 2: Build Debug**

Run:

```bash
xcodebuild -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Debug \
  -destination "platform=macOS" build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Runtime verification**

Select DaoliYu, enable real-time waveform, and play a track. Verify:

- The bars react to DaoliYu audio and stop when playback pauses.
- Starting Spotify or Music simultaneously does not change the bars.
- Switching to another media controller rebuilds the tap and restores existing
  external-player capture.
- Disabling real-time waveform restores the simulated visualizer.
