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

## A file that isn't on this Mac

Media imported on another Mac may not have reached this one yet
(`AppModel.isMediaFileMissing`). Firing it puts nothing up, so
`ServiceControls` sets `mediaProblem` with `fileMissing` and the banner reads
"File not on this Mac" instead of "Video can't play". `fireServiceItem`
returns `.unresolvable` for such an item, so a scheduled countdown is logged
as a miss rather than counted as fired, the remote's Next and Previous and
an auto-advance chain skip to the next item that can play.

## Turned videos and photos

A portrait iPhone video is stored landscape with a 90° `preferredTransform`,
and a portrait photo with an EXIF orientation. `AVPlayerItemVideoOutput`
hands over frames as stored, so `prepare` builds an `AVVideoComposition`
from the asset when the track's transform turns or flips it (not when it
only moves it, and not for alpha videos), and `MediaPlayer` sets it on the
item; `naturalSize` is the turned size. Stills with an orientation other
than 1 are decoded through ImageIO's thumbnail path at full size with the
transform applied. Import records the turned width and height.

## When a video has ended

`MediaTransportState.hasPlayedOut(at:)` is what "finished" means everywhere
(the plan's move on, end actions, the stage): stopped at its end, not
looping, and not `parkedBySeek`. A seek from the transport while paused
parks the video (seeking clamps a frame short of the end, inside the end
threshold); playing again clears it. So scrubbing a paused countdown to its
last frame doesn't move the plan on.

A video fired on its own (not a slide's background) that has played out is
taken down when the next slide goes up (`ShowState.clearEndedMedia`), unless
that slide brings its own background to the same layer. Imports are
Background videos and play on the looping layer, which slides didn't sweep,
so the countdown's 0:00 frame used to stay behind the welcome slide.

Times left (the transport strip's "left", the stage's video countdown and
the Local API's) are in real seconds: media time divided by the play rate.

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
