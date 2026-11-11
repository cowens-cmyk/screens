# Side TVs: the audience slides with larger lyrics

Settings › Screens › Side TVs. Per Mac, off until **Use side TVs** is turned on.

The room has a large centre LED wall (the Audience screen: the worship
background with two lines of lyrics small at the top) and TVs beside it.
Mirroring the Audience screen onto the TVs makes those lyrics a fraction of
the size. Side TVs is a fourth screen that shows the Audience screen's scene
with a song's lyrics drawn larger, and everything else as the room has it.

## What it shows

- **Songs** (any presentation whose Screens-by-Type row is Worship: a song,
  or a deck typed Worship): each of the slide's own plain text boxes is
  drawn **Lyrics size** times larger (1.0–2.5×, 1.6× to start). The box grows
  around its centre and stays inside a 5% safe margin (a box the theme
  already put past that line keeps its own edge, so lyrics at the top of the
  wall grow downward). The text shrinks to fit when the box can't grow as
  far as the type, never below the Audience screen's own size, and each
  written line stays on one line, so two lines on the wall are two lines on
  the TVs.
- Left as the room has it: the background and every media layer, the
  theme's own pieces (ids `theme-…`: a bar, the song title or CCLI line),
  text inside shapes, text on a path, tickers and scrolling text, masked
  text, overlays and alerts.
- **Anything else** (message, scripture, announcements, videos, a cleared
  slide): exactly the Audience screen.

## How it works

- `SlideScene/SideScreenLyrics.swift` turns the room's live scene into the
  Side TVs' scene. It's a pure function of the scene, the live presentation
  and the scale; tests in `SlideSceneTests/SideScreenLyricsTests.swift`.
- `ServiceControls.apply()` makes it from the same base scene it gives the
  room, every time the room's scene is made, as one of the live scene
  variants (key `side-tvs-lyrics`). Each variant has its own transition
  engine, so the TVs dissolve between slides with the room.
- `StreamRouter.republishStream()` routes the Side TVs screen to that key in
  the output manager's slide-theme routing, beside the livestream's designs.
  The Side TVs carry every layer.
- `ShowScreen.sideTVs` (`ThreeScreens.swift`) is the screen itself, with the
  role Audience. `ShowScreen.inUse` lists it only while it's on, so the
  arrangement, Output menus, NDI and DeckLink buttons and the top bar's
  status dots show it only then. `ShowScreens.setSideTVs(_:render:)` makes
  the screen or takes it away with its displays, NDI and DeckLink ports.
- Settings live in `ShowSetup` (UserDefaults, per Mac): `show.sideTVs.on`,
  `show.sideTVs.lyricScale`, `show.sideTVsTarget`.

## Two TVs

- One cable split to both TVs (an HDMI splitter or a distribution amp):
  set **Output** to that display. Nothing else.
- Two cables from the Mac: set **Output** to one and **Second display** to
  the other. The second display is a whole-picture slice of the same
  screen, drawn from the same scene on the same frame. It is only offered
  while the Side TVs are on a display; moving them to NDI, DeckLink or None
  removes it. Giving the second display to another screen takes it off the
  Side TVs.
- DeckLink: switch **Side TVs** on beside each port, as for any screen.

## Setting it up

1. Settings › Screens › Side TVs › **Use side TVs**.
2. Drag **Side TVs** onto the TVs' display in **Displays** (or pick it in
   **Output**). For a second TV on its own cable, pick it in **Second
   display**.
3. Fire a song and set **Lyrics size** while looking at the TVs (also in the
   screens panel: the Side TVs card's **Lyrics** menu).
