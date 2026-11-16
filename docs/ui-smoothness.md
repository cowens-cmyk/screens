# Keeping the window smooth

The booth Mac has room to spare; when Screens stutters it is the main thread
doing work every frame that it doesn't need to. Finder stays smooth because it
does none of it. These are the rules the app keeps, and where each lives.

## The plan page

The whole-plan page (`ServiceContinuousView.swift`) is one non-lazy column of
every item, so anything each item does per frame is multiplied by the plan.

- **One measurement per scroll frame.** Items and grids note their place in
  the page's content (`PresentCardFrames.noteDoc`, `noteDocGrid`) with
  `onGeometryChange`, which a scroll doesn't change. The page measures where
  its content sits in the scroll view (`contentOrigin`) once per frame, and
  every place on screen follows from that (`PresentCardFrames.frame(_:)`).
  No GeometryReader per item: its content re-ran for every item on every
  frame of a scroll or a glide.
- **Rows near the screen.** A grid works out which rows are near the screen
  as the page moves (`GridPlace`), and acts only when that changes. Rows come
  in without animation, even during a glide.
- **Sticky headers.** `StickyHeader` keeps its offset in its own state, set
  only when it changes: only the header that is stuck redraws while the page
  scrolls. Its frosted backdrop is there only while it is stuck.
- **The selection.** The page sits behind an equatable wrapper and reads the
  selected item from `PlanPageFocus`. A plan-list click, a fire or anything
  else that re-runs PlanShell doesn't rebuild the page, its grids or tiles;
  `PlanPageFocusFollow` scrolls, and grids ask `pastesAtEndCheck` when a
  paste comes.
- **Nothing a pick writes is read where the cards are built.** Measured
  with `scripts/perf/present.sh` and Instruments (SwiftUI and Time Profiler
  templates against the staged perf build), each of these re-ran every card,
  grid and tile on a pick, an 80 ms freeze per click:
  - The `ScrollPosition` binding sat in the GeometryReader that holds the
    whole page; a pick writes it. `PlanPageScrollPosition` reads it.
  - One `headerHeights` dictionary was read by every card. Each card's
    `StickySection` measures its own header; `HeaderHeightBox` mirrors them
    for the scroll actions, unobserved.
  - A grid's tile frames are in `TileFrameBox`, not `@State`, reported with
    `onGeometryChange`.
- **No `@AppStorage` in any view.** It re-runs every view holding one on any
  write to UserDefaults, whatever the key, and the app writes defaults all
  the time (the stage mode when the next item goes live, timers, the
  scheduler, AppKit's window state). The window's root held nine and every
  slide thumbnail one, so each write re-ran the window and every thumbnail.
  `@HotDefault` (HotDefault.swift) is the same declaration over one observed
  cell per key, which notifies only when that key's value changes; the page
  reads its four grid settings from `HotDefaults`. Menu `Commands` keep
  `@AppStorage`. A source sweep fails on an `@AppStorage` in a view.
- **The window's root doesn't hold the selection.** `PlanShell` owned the
  selected item and the page's scroll mark as `@State`, so every pick re-ran
  it and with it the top bar, both panels and every button and menu (36
  buttons and 13 menus a click in Instruments). The selection is a
  `PlanPageFocus` it owns and only sets; `PlanHandle`, the plan list's
  follower and the page read it. The scroll mark is in
  `PresentFocusScrollBox`, observed only for a reselect. `PlanShell` ticks
  the body meter: a pick or a fire shouldn't show it in `perf.mark`.
- **A glide builds where it lands, a row a frame.** After a pick the page
  glides for 0.3 s, and what stuttered was the glide, not one freeze: Time
  Profiler showed 2.6 frames per click over 9 ms and 1.5 over 17 ms (worst
  44-49 ms), each a frame where three or four rows of tiles were made at once
  as they came near the screen, for every item the glide passed as well as
  the one it was going to. A row of five tiles takes 10-14 ms to make.
  - `PageGlide` holds where the page will land. While it is set, `GridPlace`
    gives each grid its rows for the landing, not for where it is, so the
    items passed stay empty cells and the landing's rows are made on the way.
    `PageGlideEnds` puts each grid back to its real place when it lands.
  - `RowBuildPacer` makes one row, in one grid, per frame for the whole
    page: the grid whose missing row is nearest the screen first, and rows
    are let go only when none is waiting to be made. A row costs about
    30 ms to make, nearly all of it SwiftUI building the tiles' views (the
    app's own code in that frame is about 1 ms), so when matters more than
    how: rows on screen, or where a glide lands, are made at once a row a
    frame; the rows around the screen wait until half a second after a
    pick, a click or a fire, then come 50 ms apart, where a 30 ms frame
    moves nothing. The operator's own scrolling doesn't hold them back:
    the rows ahead of a scroll keep being made so it never reaches empty
    cells. `perf.rows` (test builds) logs when rows were made and let go
    after each glide.
  - Each row is a `GridRowSwitch` reading its own `GridRowFlag`. The built
    rows used to be a set in the grid's state: adding a row re-ran the grid
    and every tile already built in it (a tile takes a closure, so it never
    compares equal).
  - A row not built yet is a faint slide-shaped box.
  - Tile frames (for drops and the selection box) come from the grid's
    cell size; a tile measuring itself was revisited, per tile, on every
    frame of a scroll.
- **A pick's anchor is the top of its item's section** (`StickySection`),
  not the item's header: stuck, the header sits at the bottom of its
  section, and a jump up to an earlier item landed there, a grid's height
  short of its top. `scripts/perf/landing.sh <label>` clicks down, up, down,
  up and fails unless each lands with its item's top at the top.
- **Tiles.** Anything a tile works out from its slide that takes more than a
  lookup is cached by slide (`TileStepCache` for animation steps), not done in
  `body`.

- **Accessibility.** Each slide tile is one accessibility element (a button
  with its number and label), not one per text run and overlay. Something on
  the booth Mac reads the window's accessibility tree, and SwiftUI answers
  for every view it can see: on Nov 13 that was a quarter of the sampled
  freezes and one 130 s stretch at full load.

## The plan list

`RunOrderList` (ServicePlannerView.swift) builds every row, its menus and
lighting positions in one body, so that body should run for plan edits, not
clicks. Measured with `scripts/perf/present.sh`: a plan click ran it twice
(44 rows) before, none now (the List itself still redraws its 22 rows when
its selection moves).

- **Equatable.** PlanShell re-runs on every click and hands the list new
  closures; `.equatable()` compares the model, controls, render context and
  plan only. The closures read PlanShell's live state when called.
- **No `@Binding` for the current item.** A stored `@Binding` re-runs its view
  whenever the value changes, read or not (SwiftUI's `_printChanges` showed
  `_selectedItemID changed` per click). The list holds `RunOrderCurrentItem`,
  a plain value; `RunOrderCurrentFollow` binds to it.
- **Marks.** Selection, current item, drop target and row frames are in
  `RunOrderMarks`. The body reads only `multi` (the selection while more than
  one is in it). Row backgrounds, the live badge (`RunOrderLive`), the drop
  ring and the highlight read what they show.
- **Row frames** go to a `RowFrameStore`, observed only for the followed row;
  the marquee asks for them at each press.
- **Menus are built when they open** (`RunOrderMenu`), not with every row:
  the List redraws its rows on each click.
- **One container per row**, header or item: a bare `if` at the top of a
  lazy row makes SwiftUI run every row to learn its shape.

The media bin keeps its hovered and previewing tile in `MediaBinHover`, read
by the tiles: as `@State` on the bin each pointer move re-sorted the library.

`RunOrderList` and `MediaLibraryView` tick the body meter (`perf.mark`,
`perf.bodyStorm`).

## What a tile costs

Measured 2026-11-16 with Time Profiler on the perf plan (five across, M1
Max), one build with the tile's pieces switchable, 12 picks each:

| Tiles | Frames over 14 ms after the first pass | Their total |
|---|---|---|
| As shipped | 25 | 612 ms |
| No drop target, right-click menu or drag source | 15 | 323 ms |
| Picture and caption only | 14 | 316 ms |
| Empty cells | 1 | 15 ms |

- A tile takes about 5 ms to make, almost none of it the app's code: it is
  SwiftUI building the tile's views (`_makeView` for the context menu, the
  drop target, the drag source, gestures, accessibility), graph
  bookkeeping, and generic metadata. Half is the three per-tile
  interactions, half the picture and caption.
- Every built tile is also revisited on each frame of a scroll (anything on
  it that needs its place on screen: the drop target, an AppKit-backed
  view), and adds to each update of the window.
- Tried and not kept: making rows in one change instead of one a frame (same
  total, one 60 ms frame instead of two of 30; a fire landing on it would
  wait twice as long); laying a row's tiles over its empty cells as an
  overlay so the page's layout doesn't change (no difference: the cost is
  the tiles, not the layout); narrower bands of built rows (5-8% less work,
  empty cells sooner when scrolling).
- Done since (see the next section): one drop target and one menu per grid.
  The drag source stays on the tile. What is left of a tile's cost is its
  picture and caption.

Timing on this Mac drifts by half again for minutes after a build (the same
build read 40 and 20 ms for a first pass in back-to-back rounds), so compare
builds interleaved in one batch, twice, and wait for the load to settle
first (`run.sh` has `await_quiet`).

## One drop target and one menu per grid

A slide grid has one drop target (`SlideGridDropDelegate`) and one
right-click menu (`GridMenuContent`) for all its tiles, and works out the
tile under the pointer from the tiles' frames (`SlideDropPlacement.tile`),
as it already did for drops in the gaps. `scripts/perf/grid.sh <label>`
checks both through the app's own drop and menu code.

- **Why.** SwiftUI lays a real AppKit view (`_PlatformDraggingDestinationView`)
  over every `.onDrop`, and builds a context menu's machinery for every view
  that has one, so each tile paid for both when its row was built, and each
  drop view was one more thing to place on every frame of a scroll.
- **What it bought**, against 0.38.4, interleaved, three rounds of twelve
  picks: main-thread work in the 0.6 s after a plan click 247 to 215 ms
  (13% less), frames over 9 ms in the glide 1.9 to 1.2 a click, the first
  pass and the frames over 17 ms unchanged (25 ms; 0.9 a click, the rows
  built once the page is still). A wheel scroll down the page and back:
  3.9 to 3.35 s of work in 9.5 s (14% less), frames over 17 ms 56 to 45.
  Less than the switch-off experiment above suggested: turning the
  pieces off also skipped work the grid still does once.
- **The drop mark** (a line before or after a tile, a ring on it) is one
  layer over the grid reading `GridDropMarks`. As `@State` on the grid, a
  drag across the tiles re-ran the grid for each tile it passed.
- **The menu** is on the tiles' container. SwiftUI doesn't say where in a
  view a right-click was, so `SlideGridClicks` watches the app's clicks: a
  right-click or Control-click over a tile names that tile to its grid
  (`SlideGridMenuPress`) before SwiftUI sees the event, and the menu is
  built for it. Three rules keep it on the right slide:
  - SwiftUI learns of an observed change a moment later, not as it is made.
    Asked for the menu straight after the tile was named, it gave the menu
    built the time before, for another slide: 133 times in 200 in a probe,
    and never once `CATransaction.flush()` came first. Keep the flush.
  - The menu has items only for half a second after the click that named
    its tile; any other click forgets the tile. A menu asked for some other
    way (VoiceOver's, say) is empty and doesn't open. No menu is better than
    one for the wrong slide.
  - Every right-click counts as a change, so the menu is built again each
    time and shows what the last choice changed.
- **The drag source stays on the tile**, for two reasons found in a probe:
  - It is what makes a click on a slide fire while another app is in front.
    With a SwiftUI drag source under the pointer the window takes the first
    click (`acceptsFirstMouse` is true); without one that click only brings
    the window forward. An AppKit drag started from an event monitor fails
    the same way, and leaves SwiftUI's click handling waiting for a mouse-up
    it never gets.
  - A drag source on a container draws its picture in the middle of the
    container: SwiftUI centres a custom preview in the source view's frame,
    not on the pointer, and without one drags a picture of the whole grid.
  And there is nothing left to win there: a build with no drag source at
  all measured the same as one with it on the tile (216 and 215 ms a click).

## Measuring a click

`scripts/perf/present.sh <label>` (plan-list picks),
`scripts/perf/fire.sh <label>` (the arrow key, through item changes) and
`scripts/perf/landing.sh <label>` (where far jumps land) run the staged perf
build, and `scripts/perf/grid.sh <label>` checks a grid's drops and menus; `perf.mark` counts the bodies each one re-ran. For where
the time goes, record the same run with `xcrun xctrace record --template
'Time Profiler' --attach <pid>`: SwiftUI's own time shows up as layout and
graph updates, so the long freezes, not the totals, are what to compare.
For a real click's path (hit testing, the list's own mouse tracking,
gestures) where no pointer can reach the window, such as a locked screen:
write `click X Y [right|double] [cmd|shift]`, `key CODE` or
`scroll DY COUNT` (window points, origin top left; the scroll is wheel
events to the plan page) to `perf-input.txt` in the sandbox home, then
`notifyutil -p com.example.mxuslides.perf.input`; the app posts the event
into its own queue (`PerfHooks.postInput`, test builds only). `menu X Y`
asks SwiftUI for the right-click menu at a point (its items go to
`perf.menu`), and `dragover X Y PAYLOAD`, `drop X Y PAYLOAD` and `dragend`
hold, drop and take away a drag that isn't one: the calls AppKit makes for
a real drag, sent to the view SwiftUI lays over the drop target, so the
app's own drop code runs (PAYLOAD is a library id, a slide drag's text or
`file:PATH`). In place of X Y, `tile N ACROSS` is a point on tile N of the
topmost grid showing it. What these can't show is the drag source: picking
a slide up needs a real pointer.
`screencapture -l <window id>` still captures the window behind the lock.
What to compare is each click as a sequence, not its longest freeze: the
first pass, then every frame of the glide. From a Time Profiler export
(`xctrace export … time-profile`), take the main thread's busy runs (samples
not in `mach_msg`) in the 600 ms after each click: the first run is the
click's own pass; count the later runs over 9 ms and over 17 ms (a dropped
frame at 120 and 60 Hz) and note the worst. The SwiftUI template, recorded
from launch (`xctrace record --template SwiftUI --launch -- sandbox-exec …`,
so views have names), says which views those frames update.
To find what re-runs a view, `let _ = Self._printChanges()` in its body
(with stdout line-buffered) names the property; remove it before
committing. As of 0.38.3 a plan click's longest freeze is about 30-45 ms
(was 75-86), a fire within an item about 3 tiles, into the next item
about 1 grid (was every grid on the page). As of 0.38.4, against 0.38.3
interleaved on the same Mac: a pick's first pass 28 to 23 ms; frames over
9 ms per click 3.4 to 1.2 and over 17 ms 1.6 to 0.9, the ones left all
half a second after the click (the idle rows), none inside the glide.

## Periodic work

- A progress bar or countdown ticks in a `TimelineView` around only what
  changes (the bar, the time), at 10 Hz for bars and 1 Hz for times. Menus,
  gestures and lists stay outside it.
- A value set from a timer or a device poll is set only when it changes:
  Observation re-runs every view that reads a property on every set, equal or
  not (`DeckLinkOutputController.refreshStatus`, `AudioPlayer.refreshPosition`,
  `LiveAssist.heardLevel`).
- A fast value (a meter, a position) is read by the small view that shows it,
  never by a bar or a panel's top-level body.

## Drawing

Metal specifics (command buffers, feeds, validation): `docs/metal.md`.

- Docked screen previews draw at 15 fps; floating panels at 10.
- A material, glass or shadow that isn't showing is left out of the tree, not
  drawn at opacity 0: each still costs a blur or an offscreen pass every frame
  the live previews under it change (`PanelSurface`).

## Measuring

The sandboxed check (`apps/mac/scripts/perf/run.sh <commit>`) builds a commit,
runs it against its own 302-song library with no network, and compares with
`scripts/perf/baseline.json`. On the booth Mac: **Help › Save Performance
Report…**, the breadcrumbs (`perf.pass`, `perf.hitch`, `perf.pulse`) and
`sample Screens 10` while reproducing.
