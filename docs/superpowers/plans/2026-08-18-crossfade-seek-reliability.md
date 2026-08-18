# DaoliYu Crossfade and Seek Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align DaoliYu crossfade and free-main-screen seeking with Cove so fades are audible and completed drags do not snap back.

**Architecture:** `DaoliYuAudioEngine` will use item-scoped `AVMutableAudioMix` ramps instead of task-driven player-volume updates. The shared playback slider will keep its local drag state briefly after submission, while `MusicManager` applies an optimistic seek position before dispatching the controller command.

**Tech Stack:** Swift, SwiftUI, Combine, AVFoundation, Xcode.

---

### Task 1: Replace Task-Based Crossfade with Audio Mix Ramps

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift:38-223`

- [x] **Step 1: Remove task-based crossfade state**

Delete:

```swift
private var crossfadeTask: Task<Void, Never>?
```

- [x] **Step 2: Apply the outgoing ramp before observer teardown**

In `crossfadePlay`, retain the old player and call:

```swift
cleanupFadingOutPlayer()
fadingOutPlayer = oldPlayer
applyFadeOutAudioMix()
```

Do not set either player's `volume` or start a volume loop.

- [x] **Step 3: Apply the incoming ramp at readyToPlay**

Add an `applyFadeInOnReady` argument to `setupObservers` with a default of
`false`. In the `.readyToPlay` branch:

```swift
if applyFadeInOnReady {
    applyFadeInAudioMix()
}
```

Call `setupObservers(player: newPlayer, applyFadeInOnReady: true)` from
`crossfadePlay`.

- [x] **Step 4: Add Cove-equivalent mix helpers**

Add:

```swift
private func applyFadeOutAudioMix() {
    guard let item = fadingOutPlayer?.currentItem,
          let audioTrack = item.tracks.first(where: {
              $0.assetTrack?.mediaType == .audio
          })?.assetTrack else { return }

    let currentTime = fadingOutPlayer?.currentTime() ?? .zero
    let endTime = item.duration
    guard endTime.isValid && !endTime.isIndefinite else { return }

    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
    parameters.setVolumeRamp(
        fromStartVolume: 1,
        toEndVolume: 0,
        timeRange: CMTimeRange(
            start: currentTime,
            duration: CMTimeSubtract(endTime, currentTime)
        )
    )
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    item.audioMix = mix
}

private func applyFadeInAudioMix() {
    guard let item = player?.currentItem,
          let audioTrack = item.tracks.first(where: {
              $0.assetTrack?.mediaType == .audio
          })?.assetTrack else { return }

    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
    parameters.setVolumeRamp(
        fromStartVolume: 0,
        toEndVolume: 1,
        timeRange: CMTimeRange(
            start: .zero,
            duration: CMTime(
                seconds: crossfadeDuration,
                preferredTimescale: 600
            )
        )
    )
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    item.audioMix = mix
}
```

- [x] **Step 5: Simplify fading-player cleanup**

Remove task cancellation and volume resets. Keep observer removal, pause, and
reference release.

- [x] **Step 6: Parse the audio engine**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
```

Expected: exit code 0.

### Task 2: Prevent Free-Main-Screen Seek Snapback

**Files:**
- Modify: `DynamicIsland/components/Notch/NotchHomeView.swift:829-1084`
- Modify: `DynamicIsland/managers/MusicManager.swift:1303-1307`

- [x] **Step 1: Add a configurable drag release delay**

Add to `CustomSlider`:

```swift
var dragReleaseDelay: TimeInterval = 0
```

When the drag ends, submit the value and record `lastDragged`. If the delay is
positive, clear `dragging` after that delay; otherwise clear it immediately.

- [x] **Step 2: Use Cove's 0.1-second hold for playback progress**

Pass:

```swift
dragReleaseDelay: 0.1
```

from `MusicSliderView.sliderCore`. Other `CustomSlider` call sites use the
zero default and remain unchanged.

- [x] **Step 3: Apply optimistic seek state**

At the start of `MusicManager.seek(to:)`, clamp the target and immediately set:

```swift
let target = min(max(0, position), songDuration)
elapsedTime = target
timestampDate = Date()
```

Then dispatch `target` to `activeController?.seek(to:)`.

- [x] **Step 4: Parse the changed UI files**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/components/Notch/NotchHomeView.swift
xcrun swiftc -frontend -parse DynamicIsland/managers/MusicManager.swift
```

Expected: both commands exit 0.

### Task 3: Build and Run

**Files:**
- Verify: `DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift`
- Verify: `DynamicIsland/components/Notch/NotchHomeView.swift`
- Verify: `DynamicIsland/managers/MusicManager.swift`

- [x] **Step 1: Verify source invariants**

Run:

```bash
rg 'startVolumeCrossfade|crossfadeTask' DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
rg 'AVMutableAudioMix|applyFadeInOnReady' DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
rg 'dragReleaseDelay: 0.1' DynamicIsland/components/Notch/NotchHomeView.swift
```

Expected: the first command has no matches; the other commands match the new
implementation.

- [x] **Step 2: Build Debug**

Run:

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Restart Atoll**

Run:

```bash
pkill -x Atoll || true
open ~/Library/Developer/Xcode/DerivedData/DynamicIsland-baxlmerjwafjbrgyrnqxatwnauvd/Build/Products/Debug/Atoll.app
```

Expected: the rebuilt Debug process remains running.
