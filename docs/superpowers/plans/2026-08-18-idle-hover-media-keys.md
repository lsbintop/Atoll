# Idle Notch Hover and DaoliYu Media Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the collapsed notch hit area while idle and make macOS hardware media keys control DaoliYu through a valid native Now Playing session.

**Architecture:** Restore the existing idle view branch in `ContentView` so the root notch always has measurable content. Centralize DaoliYu command availability and `MPNowPlayingInfoCenter.playbackState` synchronization in `DaoliYuManager`, keeping the system remote-command path instead of intercepting hardware keys.

**Tech Stack:** Swift, SwiftUI, MediaPlayer, AVFoundation, macOS

---

### Task 1: Restore the Idle Notch Hit Area

**Files:**
- Modify: `DynamicIsland/ContentView.swift:987-998`

- [ ] **Step 1: Remove the empty duplicate idle branch**

Delete this branch:

```swift
} else if !coordinator.expandingView.show
    && vm.notchState == .closed
    && (!musicManager.isPlaying && musicManager.isPlayerIdle)
    && Defaults[.showNotHumanFace]
    && !vm.hideOnClosed {
```

Leave the following `DynamicIslandFaceAnimation()` branch and final transparent
rectangle fallback unchanged. This guarantees non-zero content in both idle
face settings.

- [ ] **Step 2: Parse the modified file**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/ContentView.swift
```

Expected: exit code 0.

### Task 2: Publish a Valid macOS Now Playing State

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuManager.swift:328-395`

- [ ] **Step 1: Add centralized media-session synchronization**

Add:

```swift
private func syncRemoteCommandState() {
    let center = MPRemoteCommandCenter.shared()
    let hasTrack = playQueue.currentTrack != nil
    let isPlaying = audioEngine.isPlaying

    center.playCommand.isEnabled = hasTrack && !isPlaying
    center.pauseCommand.isEnabled = hasTrack && isPlaying
    center.togglePlayPauseCommand.isEnabled = hasTrack
    center.changePlaybackPositionCommand.isEnabled = hasTrack
    center.previousTrackCommand.isEnabled = hasTrack
        && (audioEngine.currentTime > 3 || !playQueue.history.isEmpty)
    center.nextTrackCommand.isEnabled = hasTrack
        && (playQueue.remainingCount > 0
            || playQueue.repeatMode != .off
            || playQueue.autoPlayEnabled)

    MPNowPlayingInfoCenter.default().playbackState = {
        if isPlaying { return .playing }
        return hasTrack ? .paused : .stopped
    }()
}
```

- [ ] **Step 2: Reject commands when no track exists**

For play, pause, toggle, next, previous, and seek handlers, guard
`playQueue.currentTrack != nil`; return `.noSuchContent` when absent.

- [ ] **Step 3: Synchronize after command setup and metadata updates**

Call `syncRemoteCommandState()`:

- At the end of `setupRemoteCommands()`.
- After assigning `nowPlayingInfo` in `updateNowPlayingInfo(for:)`.
- At the end of `updateNowPlayingElapsedTime()`.
- At the end of `updateNowPlayingPlaybackState()`.
- After restoring and pausing the persisted current track.

This covers initial restoration, play, pause, resume, seek, track changes,
crossfade, and end-of-queue stop.

- [ ] **Step 4: Parse the modified file**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuManager.swift
```

Expected: exit code 0.

### Task 3: Verify Both Fixes

**Files:**
- Verify: `DynamicIsland/ContentView.swift`
- Verify: `DynamicIsland/DaoliYu/DaoliYuManager.swift`

- [ ] **Step 1: Check formatting**

Run:

```bash
git diff --check -- \
  DynamicIsland/ContentView.swift \
  DynamicIsland/DaoliYu/DaoliYuManager.swift
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

- Stop playback and clear active media presentation; hover the fully collapsed
  notch on a physical-notch display and a non-notch display. It opens.
- Start DaoliYu playback and press play/pause, previous, and next media keys.
  DaoliYu responds and Music does not launch.
- Pause and resume while observing Control Center. Its playback state follows
  DaoliYu.
- Reach the end of a queue with autoplay disabled. The media session becomes
  stopped and commands no longer claim playable content.
