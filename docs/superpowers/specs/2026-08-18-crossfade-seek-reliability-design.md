# DaoliYu Crossfade and Seek Reliability Design

## Goal

Make DaoliYu crossfade and free-main-screen progress seeking behave like Cove.

## Confirmed Problems

Atoll currently performs crossfade by repeatedly changing two `AVPlayer.volume`
values from a `Task`. Cove instead installs volume ramps on each
`AVPlayerItem.audioMix`. Atoll's implementation delays both ramps until the
incoming player is ready, so the outgoing track can remain at full volume or
finish before the ramp starts.

The free main screen submits one seek when dragging ends, but immediately clears
its dragging state. `MusicManager` then resumes timeline updates before the
asynchronous media-controller seek has updated playback state, replacing the
dragged value with the old position. The observed failure is that the slider
snaps back immediately.

## Crossfade Design

`DaoliYuAudioEngine.crossfadePlay` will follow Cove's implementation:

1. Move the current player into `fadingOutPlayer`.
2. Read its audio track from `AVPlayerItem.tracks`.
3. Apply an `AVMutableAudioMix` ramp from volume 1 to 0 over the remaining item
   duration.
4. Remove observers without pausing the outgoing player.
5. Create and start the incoming player.
6. When the incoming item reaches `readyToPlay`, read its audio track from
   `AVPlayerItem.tracks` and install a 0-to-1 ramp lasting the configured
   crossfade duration.
7. Release the outgoing player when it ends or playback is stopped.

The task-based volume loop and its cancellation state will be removed. Normal
playback continues to use full player volume.

`DaoliYuManager.crossfadeEnabled` is the only crossfade switch. The duplicate
engine-level switch and its trigger/execution guards are removed. The engine
always reports the end-window trigger once; the manager decides whether to
advance the queue and start a crossfade. This matches Cove and prevents the UI
switch from diverging from the engine gate.

## Seek Design

The existing `CustomSlider` continues to update only its local bound value while
dragging and submits exactly one seek when dragging ends.

For playback progress sliders, the dragging flag remains true for 0.1 seconds
after submission, matching Cove. Timeline updates cannot overwrite the local
target during that interval.

`MusicManager.seek(to:)` immediately applies the target position to its
displayed playback state before dispatching the controller command. The
optimistic value prevents the next timeline frame from restoring stale state.
The controller's normal polling then replaces it with the actual engine
position.

The delay is configurable on `CustomSlider` and defaults to zero so volume and
other non-playback sliders retain their current behavior.

## Buffered Seek Recovery

Seeking first uses `AVPlayer.seek`, including targets outside the currently
loaded range. Before the request, the engine stores the requested absolute
position as its recovery target.

If playback reports a rollback of more than five seconds after seeking, the
engine emits the stored requested position, not the stale position reported by
the player. The manager then reloads the stream with the server's `offset`
parameter at that requested position.

Offset reload preserves the track's full duration and publishes the requested
position immediately. Seeking to a point before an existing stream offset
reloads directly because the offset stream cannot represent negative local
time.

Resume behavior matches Cove: reload with the current offset when the item
buffer is empty, the current raw position is outside `loadedTimeRanges`, or the
pause exceeded 30 seconds. Forward buffering is increased to Cove's 600-second
value.

## Error Handling

- Missing or indefinite outgoing duration skips only the outgoing audio-mix
  ramp; playback transition still proceeds.
- Missing audio tracks skip the corresponding ramp without blocking playback.
- A seek with no active player keeps the UI stable until the next controller
  update rather than issuing repeated commands.
- A failed local seek reloads from the requested target rather than the stale
  player position.

## Verification

- Enable crossfade and verify the outgoing track fades while the incoming track
  fades in near the natural end of a song.
- Drag the free main screen progress slider repeatedly to earlier and later
  positions; verify it does not snap back.
- Verify only one seek is sent per completed drag.
- Seek beyond the loaded range and verify playback reloads from that target.
- After an offset reload, seek backward before the offset and verify playback
  reloads from the earlier target.
- Toggle crossfade off and on and verify the manager is the only switch gate.
- Verify volume/HUD sliders still release immediately.
- Parse the modified Swift files.
- Build the Debug scheme and restart Atoll.
