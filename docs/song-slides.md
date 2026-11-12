# Song slides: two lines at most

A worship slide shows at most two lines in its theme. Shepherd charts are cut
two lines a slide, but a long lyric line can still wrap in the theme's Lyrics
box and put three lines on screen ("Ancient Gates"). Such a slide becomes
slides of one or two lines, each in the same section, so it shows the same
label (two "Verse 1" slides) and the song's orders (Shepherd's, Anthem's, the
operator's) are unchanged.

## The rule

`LyricSlideFit` (PresenterCore) does the splitting; it can't draw text, so the
caller passes a line counter. `LyricSlideFitter` (SlideScene) is that counter:
the slide's words in the theme's real placeholder (`themeSlide` and
`placeholderAssignments`, the same way scripture is measured), counted with
`TextRasterizer.wrappedLineCount` at the size they're drawn. Chords are left
out of the count.

For a slide that takes more than two lines:

1. Its written lines become pieces. A line that takes more than two lines on
   its own is cut at the space nearest its middle, and again while a half is
   still too long. A line with no space stays whole.
2. Pieces go onto slides in order while they fit in two lines. A part of a cut
   line only shares a slide with the rest of its own line.
3. Chords move with their words (line and column re-indexed); one over the
   spaces where a line was cut goes with the next word.
4. Each new slide copies the original's section, design (`themeSlideName`),
   background, notes, stage layout and the rest. Actions and history stay on
   the first only, so a cue fires once where the words begin. Every piece gets
   a new id: undo matches slides by id, and with the old id kept it would take
   the added slides away and leave the first one's words cut short.

Left alone: slides that fit, blank slides, words in more than one text box,
boxes with styled runs, per-line styles, text animations on ranges or a text
link, a blank line carrying chords, and anything the counter can't measure
(no theme to measure in, path or ticker text). A theme box that shrinks to keep
lines whole never wraps, so it never splits.

A song still as Shepherd imported it (`shepherdImportHash` equal to its
`fingerprint`) gets its hash moved to the split slides, so plan sync keeps
updating it rather than treating the split as an edit.

## Where it runs

- **Shepherd imports and updates.** `ShepherdSync.importOptions` gives
  `ShepherdSongImport.Options.lineCount` a counter for the theme the song is
  shown in (the lyrics import theme for a new song, the song's own for an
  update). `ShepherdSongImport.presentation` splits before taking the
  fingerprint, so every import path (plan sync, ↻ Lyrics, Get Lyrics, Song
  Search, Import from Shepherd…, Update from Shepherd, `build_song`) gets it.
  When the theme isn't loaded, slides are cut by line count alone as before.
- **Automatically** (`SongSlideAutoFit`, app): every 15 seconds, songs whose
  index `updatedAt` differs from when they were last checked, and that have
  been quiet for a minute, are surveyed and fitted without asking. At launch
  that is the whole library. One Mac does it (`thisMacFits`): the Main Mac of
  a linked library once sync is live, or a Mac that isn't linked. Two Macs
  splitting the same slide each add new slides and the library keeps both
  sets, so an Editor Mac never splits. It does nothing while this Mac is in
  Edit, skips the song on screen, leaves every song in the current plan alone
  while anything is on the screens, and leaves a song whose theme names a
  font this Mac doesn't have (`fontsAreHere`). Each split is noted in
  Diagnostics (`songs.fitToTwoLines`).
- **File › Fit Song Slides to Two Lines…** (`SongSlideFit`, app): the same
  pass by hand over the whole library. It
  measures each song in its own theme, says how many slides in how many songs
  will change, and asks. A song edited between the check and the write is
  left as it is. Undo can't reverse it.
- **`fit_song_slides`** (Assistant and MCP): the same pass for one song
  (`presentation_id`) or the whole library. It asks first like the other
  tools that change slides; over MCP, call again with `confirm: true`.

Other ways of making songs (Import Lyrics…, the song editor, chord chart
files, the CMS) still cut by line count only; the automatic pass fits those
songs within a minute.

## Tests

- `WrappedLineCountTests` (RenderEngine): wraps, insets, shrink to keep lines
  whole, chords not counted.
- `LyricSlideFitTests` (PresenterCore): the import with a stub counter,
  refresh after a fit, chords, a long line cut at a word, what's kept and what
  is left alone.
- `LyricSlideFitterTests` (SlideScene): a theme Lyrics box two lines high; a
  wrapping slide splits with its label, a fitting one doesn't change.
