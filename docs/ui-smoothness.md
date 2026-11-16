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
- **No `@AppStorage` in the page, the grids or the plan list.** It re-runs
  its view on any write to UserDefaults, whatever the key, and the next item
  going live writes the stage mode. The page reads its grid settings from
  `HotDefaults`, which notifies only when one of them changes; views that
  only set the app mode call `HotDefaults.setAppMode`.
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

## Measuring a click

`scripts/perf/present.sh <label>` (plan-list picks) and
`scripts/perf/fire.sh <label>` (the arrow key, through item changes) run the
staged perf build; `perf.mark` counts the bodies each one re-ran. For where
the time goes, record the same run with `xcrun xctrace record --template
'Time Profiler' --attach <pid>`: SwiftUI's own time shows up as layout and
graph updates, so the long freezes, not the totals, are what to compare.
For a real click's path (hit testing, the list's own mouse tracking,
gestures) where no pointer can reach the window, such as a locked screen:
write `click X Y [right|double] [cmd|shift]` or `key CODE` (window points,
origin top left) to `perf-input.txt` in the sandbox home, then
`notifyutil -p com.example.mxuslides.perf.input`; the app posts the event
into its own queue (`PerfHooks.postInput`, test builds only).
`screencapture -l <window id>` still captures the window behind the lock.
To find what re-runs a view, `let _ = Self._printChanges()` in its body
(with stdout line-buffered) names the property; remove it before
committing. As of 0.38.3 a plan click's longest freeze is about 30-45 ms
(was 75-86), a fire within an item about 3 tiles, into the next item
about 1 grid (was every grid on the page).

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
