# Video playback failures

A video that can't play must never hold the screens. Before this was
handled, a file AVFoundation couldn't decode stayed in the media engine's
player table: the output waited on frames that never came, the plan item
kept its LIVE ring, and nothing that waits on a video's end (the countdown's
move to the next item, a video's end action) ever fired.

## What happens now

1. `MediaEngine.prepare(url:)` loads the video and audio tracks, then refuses
   the file when the asset isn't playable or the video track isn't decodable
   or playable here (`MediaEngineError.notPlayable` / `.cannotDecode`, with
   the codec's four-character code). It also records the codec and whether
   this Mac decodes it in hardware (`PreparedMedia.summary`).
2. `MediaPlayer` watches the player's status, the current item's status, the
   looper's status, `AVPlayerItem.failedToPlayToEndTime` and
   `AVPlayerItem.playbackStalled`. The first failure is reported once.
3. On a failure `MediaEngine` takes the player off its id (so `transport(id:)`
   is nil, `motion(for:)` is `.still` and the scene views stop waiting) and
   calls the handler set with `setPlaybackProblemHandler`. A report from a
   player already replaced is dropped.
4. `ServiceControls` clears every layer showing that media and sets
   `mediaProblem`, which shows a banner under the booth-message banner
   (`PlanShell`) until it's dismissed. A failed countdown does not advance
   the plan; the operator fires the next item.

A stall is only logged: AVFoundation may recover on its own.

## Breadcrumbs

Written with `DiagnosticsStore.shared.note`, collected by Help › Report a
Problem…:

| Event | When | Detail |
| --- | --- | --- |
| `media.play.start` | a video starts | name — size, codec, fps, length, hardware or software decode |
| `media.play.failed` | `prepare` refused it, or the player failed | name — what failed and the error, with its domain, code and the underlying code |
| `media.play.stalled` | the player ran out of frames | name — the player's state |
| `media.play.noPicture` | still no frame 3 s after starting | name — item status, time control status and waiting reason, position, frames shown, buffer state |
| `media.still.failed` | a picture couldn't be loaded | name — the error |

`media.play.noPicture` is the one to look for when a large file plays but
never shows: no error comes when the decoder just falls behind.

## Main thread

Starting a player doesn't block the main thread on the asset: the audio
track the sound tap needs is loaded in `prepare`, not read with the old
synchronous `tracks(withMediaType:)`. The transport (read by the main
thread's 4 Hz polls) doesn't take the player's state lock, and frame pulls
copy the pixel buffer and make its texture under a separate pull lock, so
the main thread's picture checks don't wait on a 4K frame copy.
