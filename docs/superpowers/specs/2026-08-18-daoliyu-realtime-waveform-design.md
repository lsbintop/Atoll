# DaoliYu Real-Time Waveform Design

## Goal

When DaoliYu is the selected media controller and real-time waveform is enabled,
the visualizer must reflect only audio produced by DaoliYu playback. It must not
show the simulated random animation or mix audio from external music apps.

## Current Problem

`AudioVisualizerView` explicitly routes DaoliYu to `AudioSpectrumView`, which is
the simulated visualizer. The existing `AudioTap` also builds its process tap
only from known external music applications, so it cannot capture DaoliYu audio
produced by Atoll's own `AVPlayer`.

## Design

Keep the existing Core Audio process-tap architecture and make its target list
depend on the selected media controller:

- When `.daoliYu` is selected, resolve only Atoll's current process into an
  audio process object and use it as the `CATapDescription.processes` value.
- For every other media controller, retain the existing external music
  application discovery and Bluetooth/Spotify behavior.
- Observe changes to `Defaults.mediaController`. When the real-time waveform
  setting is enabled, restart `AudioTap` so the process target is rebuilt.
- Observe DaoliYu playback entering the playing state and retry the tap start.
  This covers launches where Core Audio has not created Atoll's audio process
  object until the first `AVPlayer` begins output.
- Let `AudioVisualizerView` select `RealTimeAudioSpectrumView` for DaoliYu under
  the same real-time waveform preference as every other controller.
- If the process tap cannot start or produces no samples, the real-time
  visualizer remains at its zero state. It must not fall back to random bars
  while claiming to be real-time.

## Boundaries

This change does not modify DaoliYu's `AVPlayer`, stream loading, seek recovery,
queue behavior, or `AVMutableAudioMix` crossfade implementation. Capturing the
Atoll process externally avoids sharing or replacing the player's audio mix.

## Verification

- With DaoliYu selected and playing, bar magnitudes respond to its audio.
- Pausing DaoliYu returns the bars to zero.
- Simultaneously playing an external app does not affect the DaoliYu waveform.
- Switching away from DaoliYu rebuilds the tap and restores existing external
  player capture.
- Disabling real-time waveform still selects the simulated visualizer.
- The project builds successfully in Debug configuration.
