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
- **One container per row**, header or item: a bare `if` at the top of a
  lazy row makes SwiftUI run every row to learn its shape.

The media bin keeps its hovered and previewing tile in `MediaBinHover`, read
by the tiles: as `@State` on the bin each pointer move re-sorted the library.

`RunOrderList` and `MediaLibraryView` tick the body meter (`perf.mark`,
`perf.bodyStorm`).

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
