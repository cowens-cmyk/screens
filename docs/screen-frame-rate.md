# Screen size and frame rate

Each screen (Audience, Livestream, Stage, Side TVs) is a `PlaceholderScreen`
with its own width, height and `framesPerSecond`, kept per Mac in
`outputs.placeholderScreens`. Settings › Screens sets them per screen:
**Resolution** (1080p or 4K) and **Frame Rate** (`ShowScreens.frameRates`:
24, 25, 30, 50, 60).

- **Default.** A new screen is 1920×1080 at `ShowScreens.defaultFramesPerSecond`
  (60), so 1080p60.
- **Older setups.** Screens used to be made at 30. `ShowScreens.ensure` moves
  every screen under 60 to 60 once per Mac (`screens.movedToSixty.v1`), before
  NDI and DeckLink restore, and notes each in Diagnostics (`screens.frameRate`).
  After that the rate is whatever Settings says.
- **Changing it.** `ScreenOutput.setFrameRate` rebuilds the screen and restarts
  its NDI sender and DeckLink carry, which take their rate when they start.
- **NDI** sends at the screen's rate.
- **DeckLink.** With no format chosen the helper asks
  `DeckLinkDisplayMode.automatic`, after leaving out modes that can't key
  when keying is on. In order: the card's own setting when it is progressive
  and at the screen's size and rate (so 1080p60 over 1080p59.94); the mode at
  the screen's size and rate, progressive and fractional first (1080p59.94
  for 1080p at 60); the card's setting at that size, whatever it is; the
  fastest standard rate under the screen's. Left at its default the card says
  1080i59.94, which is how a 1080p screen went out interlaced before.
- **Each port's modes** (`DeckLinkDeviceCatalog.displayModes`) are asked of
  the helper once per port by the 8 s background look, again when a port
  comes back, on every look while a port's modes came back empty (a failed
  reply or a helper not ready yet), and for every port when Settings opens
  (`DeckLinkModeAsking`). An empty answer never replaces modes a port gave
  before, and `decklink.modes` is written only when a port's modes change.
- **Video delay** is counted in frames, so a change of rate rescales it to
  keep its time (`ShowScreens.keepDelayTime`).
- **A display** (HDMI, DisplayPort) is drawn at the display's own refresh rate.
