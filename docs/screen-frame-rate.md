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
- **DeckLink.** With no format chosen the helper uses the card's configured
  output mode when it matches the screen's size, else
  `DeckLinkDisplayMode.bestMatchAtOrBelow`: the mode at the screen's rate (the
  fractional one first, so 1080p59.94 for 60), else the fastest standard rate
  under it that the port has, so a card that tops out at 1080p30 still sends.
- **A display** (HDMI, DisplayPort) is drawn at the display's own refresh rate.
