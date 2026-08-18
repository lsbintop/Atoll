# Idle Notch Hover and DaoliYu Media Keys Design

## Goal

Keep the fully collapsed notch hoverable while no media is playing, and make
macOS hardware media keys control DaoliYu without launching Music.

## Root Causes

### Idle hover

`ContentView.NotchLayout()` contains two consecutive idle-state branches with
the same conditions. The first branch has no content, so it consumes the idle
case before `DynamicIslandFaceAnimation()` or the explicit transparent fallback
can render. The collapsed root view consequently loses its intended hit area.

### Media keys

DaoliYu publishes `MPNowPlayingInfoPropertyPlaybackRate` in the Now Playing
dictionary but never updates `MPNowPlayingInfoCenter.playbackState`. On macOS,
Apple requires this property to be set whenever playback starts or stops;
otherwise remote commands may not be routed to the app. With no recognized
active media session, macOS falls back to launching Music.

## Design

### Stable idle hit area

- Remove the empty duplicate idle branch.
- Preserve the existing idle face when `showNotHumanFace` is enabled.
- Preserve the existing explicitly sized transparent rectangle when the idle
  face is disabled.
- Do not change hover timing, open/close animations, or screen-specific hidden
  edge polling.

### Native media session

- Keep `MPRemoteCommandCenter` as the only playback-key integration.
- Set `MPNowPlayingInfoCenter.default().playbackState` to:
  - `.playing` while DaoliYu is playing.
  - `.paused` while a current track exists but playback is paused.
  - `.stopped` after playback stops or the queue has no current track.
- Update the playback state whenever Now Playing metadata, elapsed time, or
  play/pause state is updated.
- Republish the restored current track after app launch, even though restored
  playback starts paused, so macOS has a media session before the first key
  press.
- Synchronize remote-command availability:
  - Play is enabled when a current track exists and playback is paused.
  - Pause is enabled while playback is active.
  - Toggle play/pause is enabled whenever a current track exists.
  - Previous and next remain enabled only when their queue actions are valid.
- Return `.noSuchContent` from remote commands when no current track exists,
  rather than claiming success and allowing an invalid playback transition.

## Boundaries

- Do not intercept `NX_KEYTYPE_PLAY` through `MediaKeyInterceptor`.
- Do not require Accessibility permission for playback keys.
- Do not modify DaoliYu audio streaming, seek, crossfade, queue ordering, or
  external-player control behavior.

## Verification

- With no current media and the notch fully collapsed, hovering opens it on
  both physical-notch and non-notch displays.
- The idle face setting works in both enabled and disabled states.
- While DaoliYu is playing, play/pause, previous, and next media keys control
  DaoliYu and do not launch Music.
- Pausing and resuming updates macOS Now Playing state correctly.
- With no DaoliYu track, remote commands do not claim successful playback.
- Debug and Release builds succeed.
