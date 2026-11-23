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

## Every screen its own frame

One `MediaPlayer` feeds every screen showing its video: the Audience
preview (at the display's refresh, asking for its next refresh), the docked
previews at 15 fps, each DeckLink port at its own rate and clock, the side
TVs and the stage. The player's `AVPlayerItemVideoOutput` hands each frame
out once. It used to keep only the newest, so whichever screen asked
furthest ahead took the next frame and every other screen showed it early;
each screen's picture moved on at another screen's clock, held for one
refresh and then three. On Nov 22 the pre-service loop's 30 fps videos
juddered on the room screens: on the Audience preview, captured at 60 Hz
from the booth display, gaps of 16 and 50 ms between picture changes
outnumbered the steady 33 and 67 ms ones about two to one (a plain
`AVPlayerLayer` playing the same way measured 1% uneven).

`MediaPlayer.surface(at:)` now pulls every frame due by the asking screen's
time, in order (`nextPull`), into a small ring (`FrameRing`, 8 frames), and
each screen takes the newest frame whose time has come at its own time. A
new item (a loop's next pass), a seek or a pause starts the ring again.
`testEachScreenGetsTheFrameForItsOwnTime` plays a 30 fps clip to a 60 Hz
screen and a 50 Hz one asking 25 ms ahead: the 60 Hz screen held its frames
for the steady two refreshes a third of the time before, nine in ten or
more now. The sandboxed perf build can't show it end to end (it has no
DeckLink ports, and with previews only both builds were even); the booth's
Audience preview is the place to measure it again after a release.

### Away from the frame edges

The `media.cadence` breadcrumbs (CadenceProbe, every 10 s per screen) then
showed one more case, on 0.45.5: a whole video uneven on every DeckLink
port while the others were even. A port renders on its own steady timer,
and where its ticks fall against the video's frames depends on when the
video started. For "Ways to Give" they fell within 2 ms of a frame's edge
on 91-95% of renders, so a millisecond of timer jitter flipped each render
between two frames: 16-44% of holds uneven, about 50 frames skipped in 10 s
on the LED wall. The next video started at another phase and was even.

`CadenceLock` (in FrameRing.swift) gives each screen, by its RenderConsumer
label, a fixed shift of the time its frame is chosen for, once its interval
is known and fits the frame evenly (30 fps at 15, 30 or 60 Hz): the renders
then fall half an interval past an edge, as far from one as they can be.
The shift stays under half a frame and moves again only when the clocks
drift a render to within a sixth of an interval of an edge. Rates that
can't be even (25 fps at 60 Hz) keep the old choice. `CadenceLockTests`
replays the LED wall's case: the old choice skips frames, the lock holds
every frame once. Live, "near a frame edge" in the breadcrumbs should stay
low on every port.
