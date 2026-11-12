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
  the lower-third designs its slides name, and the plan's series theme
  (`themesFilled`), so a fire never waits on a theme.
- **Pictures.** `MediaEngine.standBy(still:)` decodes the file to a texture
  and keeps it by URL. `showStill(url:id:)` takes it from there.
- **Videos.** `MediaEngine.standBy(video:)` opens the asset (tracks read,
  decodability checked) and keeps the `PreparedMedia`; `prepare(url:)` returns
  it. The file is then read from end to end, so the system keeps it in its
  file cache.
- **Thumbnails.** Each one's poster (`ThumbnailStore.poster`), so the plan
  page's tiles have their pictures at once.

## Limits

Pictures are held up to an eighth of the Mac's memory (8 GB of 64) and video
files read through up to a quarter, counted in plan order, so the start of the
service is covered first on a small Mac. A picture left out is decoded when
it's shown, as before. What belongs to another plan is released at the start
of each pass (`releaseStandby(keeping:)`); media on a screen keeps its own
picture.

## Seeing it

The Screens panel shows "Loading the plan into memory" with a bar while a pass
runs (`PlanPreloadStatus`). Each pass that loaded something notes
`plan.preload` in Diagnostics with the counts and the time it took.

One that fails to play is dropped from standby, so the next try opens it
afresh.

## Players standing by

Opening a file is the small part of starting a video; the wait is the player
and its decoder coming up. As the plan moves on (`watchPosition`: the live
item or deck changing) and after each pass, `readyUpcomingPlayers` takes the
videos of the item on screen and the next two (`upcomingVideos`: plan video
items, and every slide's effective background, each with the loop it will be
played with), up to six, and has the engine make and preroll a player for each
(`MediaEngine.standBy(playing:loop:options:)`), paused on its first frame and
under no id, so it is on no screen and in no transport list. `play` takes the
one whose file, loop and trim match and starts it; anything else gets a fresh
player as before. Players for videos no longer coming up are stopped
(`releaseStandbyPlayers`), and one already playing needs none.
