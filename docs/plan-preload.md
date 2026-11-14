# The plan in memory

`PlanPreloader` (app) loads the current plan into memory when Screens opens,
and again two seconds after the plan, its presentations, themes or media
change. Before it, a slide's words went up at once and its picture a moment
later, once the file had been read and decoded, so a slide could be seen
building.

## What it loads

In the order the plan reaches them (stage layouts first):

- **Presentations and themes.** The plan's decks (`presentationsFilled`) and
  every theme they draw with: the deck's, its slides', its livestream theme,
  the lower-third designs its slides name, the themes those send the
  livestream to (`Theme.streamThemeReferences`), the plan's and the church's
  series theme, and each deck's type's lower-third design in Screens by Type
  (`themesFilled`, twice, since a theme read in can name more), so a fire
  never waits on a theme.
- **Which media, in what order** is `PlanPreloadPlan.mediaIDs`
  (PresenterCore, tested): stage layouts; then per item a video item's file,
  or a deck's themes' media, backgrounds, slides' media (a slide's livestream
  lower-third picture included, `MediaReferences.ids(in: slide)`), the media
  its type's actions fire (`PresentationTypes.actions`), and the media the
  item's own macros fire; then the livestream themes' media.
- **Pictures.** `MediaEngine.standBy(still:)` decodes the file to a texture
  and keeps it by URL. `showStill(url:id:)` takes it from there.
- **Videos.** `MediaEngine.standBy(video:)` opens the asset (tracks read,
  decodability checked) and keeps the `PreparedMedia`; `prepare(url:)` returns
  it. The file is then read from end to end, so the system keeps it in its
  file cache.
- **Audio.** An audio item's file (`PlanPreloadPlan.audioIDs`) is read
  through like a video's, so `AudioEngine.play`, which opens it on the main
  thread, doesn't wait on the disk.
- **Thumbnails.** Each one's poster (`ThumbnailStore.poster`), so the plan
  page's tiles have their pictures at once.

## Limits

`PlanPreloadPlan.budget(physicalMemory:)`, counted in plan order:

| Mac | Pictures (decoded) | Files read through |
| --- | --- | --- |
| 8 GB | 1 GB (an eighth) | 2 GB (a quarter) |
| 16 GB | 2 GB | 4 GB |
| 32 GB | 8 GB (a quarter) | 8 GB |
| 64 GB | 16 GB | 16 GB |

16 GB and under keep the old caution, so the start of the service is covered
first; above that a whole plan fits (a 300-picture message is about 2.5 GB
decoded). Pictures are real memory (each is a GPU texture); files read through
are the system's file cache, which it gives back by itself. A picture left out
is decoded when it's shown, as before. What belongs to another plan is
released at the start of each pass (`releaseStandby(keeping:)`); media on a
screen keeps its own picture.

**Memory pressure.** On macOS's warning (`DispatchSource` memory pressure,
warning or critical) the pass under way stops and everything standing by is
released; media on a screen keeps its own copy. When macOS reports normal
again the plan loads again five seconds later.

## Seeing it

Loading shows in the main window's activity bar (`ActivityBoard`, the line
under any import): "Loading the plan into memory 12 of 340" with a bar, at
launch, when another plan is opened and after memory came back; a pass after
an edit to the same plan loads quietly. When it's done it says "Plan in
memory: 340 files" for 5 seconds, or, when pictures didn't fit, how many and
why for 20 seconds (a quiet pass says so only when that number changes).
Being let go of for memory says so too. Each pass that loaded something notes
`plan.preload` in Diagnostics with the counts and the time it took.

All loading runs at utility priority off the main thread. A slide fired while
a pass runs loads what it needs itself, as before, and a newer pass (another
plan, an edit) stops the old one at its next file (`generation`).

One that fails to play is dropped from standby, so the next try opens it
afresh.

## What a first showing still does

- **Text.** Each text box is laid out and rasterized (CoreText into a texture)
  the first time a screen draws it, on the render thread, cached for 10 s
  after last use per screen size (`Compositor.textTextures`). Not preloaded:
  a warm-up would be evicted before the slide is shown, and every screen
  (room, stream, side TVs, stage) has its own size.
- **Alerts** read their preset's theme when fired; not preloaded.
- **Another deck fired by an action** (`firePresentation`) and **combos**
  (`fireCombo`) aren't followed.
- **Playlists** in the plan aren't preloaded.

## Players standing by

Opening a file is the small part of starting a video; the wait is the player
and its decoder coming up. As the plan moves on (`watchPosition`: the live
item or deck changing) and after each pass, `readyUpcomingPlayers` takes the
videos of the item on screen and the next two (`PlanUpcomingVideos.videos`
in SlideScene: plan video items, and every slide's effective background, each with the loop it will be
played with), up to six, and has the engine make and preroll a player for each
(`MediaEngine.standBy(playing:loop:options:)`), paused on its first frame and
under no id, so it is on no screen and in no transport list. `play` takes the
one whose file, loop and trim match and starts it; anything else gets a fresh
player as before. Players for videos no longer coming up are stopped
(`releaseStandbyPlayers`), and one already playing needs none.
