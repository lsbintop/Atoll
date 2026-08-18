# Buffered Seek and Crossfade Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover failed streaming seeks at the requested position and make the DaoliYu manager the single crossfade switch source.

**Architecture:** `DaoliYuAudioEngine` retains the requested seek target, detects rollback, and reports that target for offset reload. `DaoliYuManager` preserves duration across reloads, handles backward seeks before the active offset, and exclusively gates crossfade behavior.

**Tech Stack:** Swift, AVFoundation, Combine, Xcode.

---

### Task 1: Align Buffered Seek Recovery with Cove

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift:104-164`
- Modify: `DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift:323-389`

- [x] **Step 1: Retain the requested seek target**

In `seek(to:)`, set `lastReportedTime = time` before calling `AVPlayer.seek`.
The completion handler clears only `isSeeking`.

- [x] **Step 2: Recover rollback at the requested target**

Change the rollback branch to:

```swift
if !isSeeking,
   isPlaying,
   lastReportedTime > 5,
   actualTime < lastReportedTime - 5 {
    let expectedPosition = lastReportedTime
    lastReportedTime = 0
    onBufferInvalidated?(expectedPosition)
    return
}
```

- [x] **Step 3: Match Cove resume validation**

Before resuming, test the current raw time against `loadedTimeRanges`, together
with `isPlaybackBufferEmpty` and the 30-second pause limit. Emit
`onBufferInvalidated?(currentTime)` when any condition fails.

- [x] **Step 4: Match Cove forward buffering**

Set:

```swift
item.preferredForwardBufferDuration = 600
```

- [x] **Step 5: Parse the audio engine**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
```

Expected: exit code 0.

### Task 2: Preserve State Across Offset Reload

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuManager.swift:19-20`
- Modify: `DynamicIsland/DaoliYu/DaoliYuManager.swift:110-183`

- [x] **Step 1: Reload backward seeks before the current offset**

In `seek(to:)`, call `handleBufferInvalidated(at:)` when the requested time is
less than `audioEngine.timeOffset`; otherwise perform the local engine seek.

- [x] **Step 2: Preserve duration and position**

In `handleBufferInvalidated`, save `audioEngine.duration`, call
`audioEngine.play` with the requested offset, restore duration and current time,
set `lastPositionReport`, and update Now Playing elapsed time.

- [x] **Step 3: Remove the duplicate engine crossfade switch**

Change the manager property to:

```swift
@Published var crossfadeEnabled = false {
    didSet { schedulePersist() }
}
```

Remove the engine's `crossfadeEnabled` property. The engine always emits its
single end-window callback, and `handleCrossfadeTrigger` remains the only switch
guard.

- [x] **Step 4: Parse the manager**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuManager.swift
```

Expected: exit code 0.

### Task 3: Build and Restart

**Files:**
- Verify: `DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift`
- Verify: `DynamicIsland/DaoliYu/DaoliYuManager.swift`

- [x] **Step 1: Verify source invariants**

Run:

```bash
rg 'crossfadeEnabled' DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
rg 'expectedPosition|loadedTimeRanges|preferredForwardBufferDuration = 600' \
  DynamicIsland/DaoliYu/DaoliYuAudioEngine.swift
```

Expected: the first command has no matches and the second matches all recovery
markers.

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
