# Side TVs: the audience slides with larger lyrics in the middle

A fourth screen beside Audience, Livestream and Stage, for the TVs beside the
centre LED wall. At Hope it goes out of the DeckLink port **EXTRA - 4**.

The wall (the Audience screen) has the worship background with two lines of
lyrics small at the top. Mirrored onto the TVs those lyrics are a fraction
of the size. The Side TVs show the Audience screen's scene with a song's
lyrics larger and in the middle of the TV, and everything else as the room
has it.

## Turning it on

Side TVs is offered everywhere a screen is chosen: Settings › Screens ›
**Outputs** (the menu beside each display and DeckLink port), the
**Displays** chips and right-click menu, NDI, and the screens panel's eye
menu (**Turn On Side TVs**). Choosing it for an output makes the screen
(`ScreenOutput.making`), so no separate switch is needed. **Use side TVs**
in its section still turns it off, which takes it off every output so the
Mac stops drawing it.

## What it shows

- **Songs** (any presentation whose Screens-by-Type row is Worship: a song,
  or a deck typed Worship), when the slide's lyrics are one text box (the
  usual case):
  - The words are drawn **Lyrics size** times larger (1.0–2.5×, 1.6× to
    start) in the whole safe area of the TV (5% margins), centred across
    and down. They wrap in lines of about equal length and shrink to fit,
    never below 1.25× the wall's size.
  - A bar or band of the theme's (an id `theme-…` that isn't text, overlaps
    the wall's lyrics box and covers less than half the picture) is left
    off: it sits behind the lyrics at the top of the wall and would be
    empty there once the words move to the middle. A full-screen backdrop
    and the theme's words (the CCLI line, a song title) stay.
  - Words with no shadow or outline of their own get a soft shadow, so they
    read over a moving background.
  - **Darken background** (0–60%, off to start) lays black over the
    background and media, under the words.
- Several text boxes on a slide each grow around their own centre, so they
  don't cover each other; nothing is moved to the middle or left off.
- Left as the room has it: the background and media, text inside shapes,
  text on a path, tickers and scrolling text, masked text, overlays and
  alerts.
- **Anything else** (message, scripture, announcements, videos, a cleared
  slide): exactly the Audience screen.
- **A slide with its own Side TVs picture** (`Slide.sideTVsMediaId`): that
  picture instead of any of the above, centred with its proportions kept,
  over black so the room's background doesn't show around it. Overlays and
  alerts stay. A picture that's left the library falls back to the room's
  slide.

## Sermon slides made three ways

A sermon slide can be exported three times: `Slide01_Wide` for the wall,
`Slide01_LowerThird` for the livestream and `Slide01_SideTVs` (or
`Slide01_SideTV`) for the TVs. Dropping them on a presentation, or uploading
them in the CMS, makes one slide each: the wide picture is the slide, the
lower third its livestream picture, the side TVs one its Side TVs picture.
Dropping only the `_Wide` pictures brings the other two from the same
folder; dropping only `_SideTVs` pictures onto a presentation puts each on
the slide with its name. Case, and a space or hyphen for the underscore,
don't matter (`LowerThirdPairing`, and `pairName`/`pairPlan` in the CMS).
Right-click a slide › **Side TVs** to see, choose or clear its picture
(**Room's Slide** clears it). A change shows the next time the slide goes
live.

## Every output comes back

Each output's screen is saved as it is chosen: displays with the screens
(`RenderContext.savePlaceholderScreens`), DeckLink ports in
`DeckLinkScreenOutputs` (`decklink.screenPorts`), NDI in `ndi.screenBackings`,
and Side TVs being on in `show.sideTVs.on`. At launch the screens are made
first (`ShowScreens.ensure`), then NDI and DeckLink restore onto them, so a
quit, a restart or a crash brings each screen back on the outputs it had. A
port or display that isn't there yet (the card's driver still starting)
keeps its choice and is listed under Outputs as "not found yet".
`scripts/perf/outputs.sh` checks this with the booth's four ports, through
a quit and a kill.

## How it works

- `SlideScene/SideScreenLyrics.swift` turns the room's live scene into the
  Side TVs' scene. It's a pure function of the scene, the live presentation,
  the scale and the darkening; tests in
  `SlideSceneTests/SideScreenLyricsTests.swift`.
- `ServiceControls.apply()` makes it from the same base scene it gives the
  room, every time the room's scene is made, as one of the live scene
  variants (key `side-tvs-lyrics`). When the live slide has a Side TVs
  picture, `SlideScene/SideTVsPicture.swift` makes that variant instead (the
  slide layer swapped for black and the picture; tests in
  `SideTVsPictureTests.swift`), and the picture is added to the media the
  screens want (`syncMedia`). Each variant has its own transition
  engine, so the TVs dissolve between slides with the room.
- `StreamRouter.republishStream()` routes the Side TVs screen to that key in
  the output manager's slide-theme routing, beside the livestream's designs.
  The Side TVs carry every layer.
- `ShowScreen.sideTVs` (`ThreeScreens.swift`) is the screen itself, with the
  role Audience. Every menu that chooses a screen for an output lists it;
  `ShowScreen.inUse` (the screens made at launch, the per-screen sections
  and the top bar's status dots) has it only while it's on.
  `ShowScreens.setSideTVs(_:render:)` makes the screen or takes it away with
  its displays, NDI and DeckLink ports; `ScreenOutput.making` calls it when
  Side TVs is chosen for an output.
- Settings live in `ShowSetup` (UserDefaults, per Mac): `show.sideTVs.on`,
  `show.sideTVs.lyricScale`, `show.sideTVs.dim`, `show.sideTVsTarget`.

## Two TVs

- One cable split to both TVs (an HDMI splitter or a distribution amp):
  set **Output** to that display. Nothing else.
- Two cables from the Mac: set **Output** to one and **Second display** to
  the other. The second display is a whole-picture slice of the same
  screen, drawn from the same scene on the same frame. It is only offered
  while the Side TVs are on a display; moving them to NDI, DeckLink or None
  removes it. Giving the second display to another screen takes it off the
  Side TVs.
- DeckLink: choose **Side TVs** beside each port under **Outputs**, as for
  any screen.

## Setting it up

1. Settings › Screens › **Outputs**: beside **EXTRA - 4** (or the TVs'
   display), choose **Side TVs**. That turns them on, and they get a preview
   in the screens panel between Audience and Livestream. For a second TV on
   its own cable, pick it in the Side TVs section's **Second display**.
2. Set **Darken background** if the words are hard to read on a bright
   background.
3. Fire a song and set **Lyrics size** while looking at the TVs (also in the
   screens panel: the Side TVs card's **Lyrics** menu, which has **Choose Its
   Output…** too).
