# Stage and livestream tags

Each plan item shows what it does to the stage display and the livestream in a
couple of words. The Mac works them out in
`PresenterCore/Library/StageStreamTags.swift`; the CMS browser editor ports the
same rules. Change both together.

Inputs are only synced documents: the plan (`service`), the item's
`presentation` or `media`, `slideBuildingSettings` and `theme` documents. The
livestream tag assumes the operator's switch is on Lower Third (the usual; the
switch is per Mac and not synced). Full Screen and Transparent on that switch,
picked by hand or by a `setStreamMode` action, last only while the item is live:
`StreamRouter.itemFired` calls `ShowSetup.followPresentations()` when a slide
from a different plan item goes live, before that item's own actions run. The
switch isn't saved between runs.

In Present, clicking a presentation's tags opens `PresentationScreensSheet`
(`apps/mac/Sources/SlideScreensSheet.swift`). It sets `presentation.category`,
`streamThemeId` and `stageLayoutId`, and can clear every slide's own
`streamDesign` and `stageLayoutId`. One slide's choices are set with
right-click › Screens… (`SlideScreensSheet`).

Strings are exact. Help text: `Stage display: <stage>. Livestream: <stream>.`

## Shared definitions

- **Type** of a presentation: `presentation.category` when non-empty, else
  `"Worship"` when `presentation.presentationKind == "song"`, else none.
- **Actions** for an item (or one slide), in this order: `item.actions`, then
  the actions of the `slideBuildingSettings.presentationTypeRules` entry whose
  `category` matches the type (case-insensitive), then the slide's `actions`
  (for an item, its first slide in `presentation.slides`).
- **Plays once**: a media document with `mediaKind == "video"` that doesn't
  loop. Loops = the slide background's `loops` when set, else the media's own
  choice: `loopOverride` when set; else `true` when `loops` is true; else
  `false` when `endAction` is set; else its folder's default (only the Media
  Library's worship-background folders loop; treat any other as `false`).
- **Video only**: every slide considered (the item's `presentation.slides`, or
  the one slide) has a `background` whose `mediaId` is a media document that
  plays once. An empty deck is not video only.
- **Last presentation item**: the last item in `service.items` with
  `itemKind == "presentation"` and not hidden.
- Items with `itemKind` other than presentation or media, and items whose
  document isn't found, have no tags.

## Media items (`itemKind == "media"`)

| Media | Stage | Livestream |
|---|---|---|
| plays once | Video time left | Full screen |
| anything else (picture, looping video) | No change (Before service when `item.isPreService`) | No change |

## Presentation items: stage, first match wins

1. `item.isPreService == true`, or `presentation.id ==
   slideBuildingSettings.serviceDay.preServicePresentationId` → **Before service**
2. `slide.stageLayoutId` (per slide) or `presentation.stageLayoutId` non-empty →
   **Own layout**
3. First action with `kind == "setStageMode"`, by `stageMode`: `worship` →
   **Lyrics + chords**, `message` → **Message timer**, `preService` → **Before
   service**, `announcements` → **Announcements**, `mirror` → **Audience
   screen** (other values fall through)
3a. Type `Announcements` → **Announcements** (before the video rule: a video
   in the announcements doesn't switch the stage)
4. Video only → **Video time left**
5. `item.isWalkout == true`, or `presentation.id ==
   slideBuildingSettings.serviceDay.walkoutPresentationId` → **Before service**
6. Type `Sermon` → **Message timer**; type `Worship` → **Lyrics + chords**
7. Last presentation item → **Before service** (its last slide puts the stage
   there)
8. **No change**

## Presentation items: livestream, first match wins

1. Video only → **Full screen**
2. First action with `kind == "setStreamMode"` and `streamMode != "auto"`:
   `fullScreen` → **Full screen**, `off` → **Camera only**
3. Each slide's own choice, `slide.streamDesign`:
   - `mediaId` non-empty and `mode == "design"` → **Lower third picture**
   - `mode == "audience"` → **Full screen**
   - `mode == "clear"` → **Camera only**
   - `mode == "design"` (no picture) → **Lower third**
   - absent → the set-up look (below)

   If every slide has its own choice: all the same → that; otherwise **Varies
   by slide**. If none has one → the set-up look. If some do: each slide
   without one takes the set-up look; all the same → that, otherwise **Varies
   by slide**. For a single slide's tag, use just that slide.
4. The set-up look:
   1. `presentation.streamThemeId` non-empty → **Lower third**
   2. The type's row in `slideBuildingSettings.typeScreens` (row `category`
      matched case-insensitively against the Screens type: `Worship`,
      `Sermon`, `Bible`, `Announcements`, anything else `Other`). Its
      `stream`: `"audience"` → **Full screen**; `"clear"` → **Camera only**;
      `"design"` with a non-empty `streamThemeId` → **Lower third**;
      `"series"` → **Series lower third** when `service.sermonThemeId` is
      non-empty, else go on. `"theme"`, no row, or an unknown value: the
      default — `"series"` for `Sermon`, `"theme"` for everything else.
   3. The slides' themes (`slide.themeId` when non-empty, else
      `presentation.themeId`), each:
      - `streamLowerThirdThemeId` non-empty, or any `streamDesigns` entry with
        `mode == "design"` → **Lyrics lower third** for type Worship, else
        **Lower third**
      - else any `streamDesigns` entry with `mode == "audience"` → **Full
        screen**
      - else (or theme not found) → **Camera only**

      All the slides' themes agree → that; otherwise **Varies by slide**.

## Examples

| Item | Stage | Livestream |
|---|---|---|
| A song with a lyrics theme | Lyrics + chords | Lyrics lower third |
| The message, series set on the plan | Message timer | Series lower third |
| The message with `_LowerThird` pictures on every slide | Message timer | Lower third picture |
| Transition: one slide, the bumper video as its background | Video time left | Full screen |
| Pre-service slideshow | Before service | (its slides' look) |
| Walkout with a Full Screen stream action, last in the plan | Before service | Full screen |
| Walkout item (`isWalkout`), any slide of it | Before service | (its slides' look) |
