# Black screen

A switch in the Screens panel (the bar at the bottom of the right column), the
**Present › Black Screen** menu item and **F4** (rebindable in Settings ›
Keyboard, group Clear Layers). Every audience screen and the livestream show
solid black while it is on; the stage display is untouched.

## What it does

- Audience screens: black, whatever is live. Slides, media and overlays keep
  running underneath, so turning it off puts the room back where it was.
  Music is not stopped.
- Livestream: **opaque** black (alpha 1). A cleared livestream is transparent
  so the camera shows through; Black is the one state where it isn't. The
  ATEM follower sees it as full screen and cuts its keyer on, so the stream
  really goes black at the switcher, not just in Screens.
- Stage screens (role Confidence): unchanged. A screen's own test pattern and
  sync test still win, since they are set up on purpose. Signage on an
  audience screen is covered too. With the stage on Audience Screen (or a
  slide's Show on Stage Display), the stage keeps showing the room's slides
  and video under the cover.
- Previews (the Audience and Livestream cards, the folded strip, the booth
  board's picture of the room) show what the screen shows, so they go black.

## What ends it

Any of these, because the operator is putting something on the screens:

- firing a slide (including the one already live), media, an overlay, or an
  alert that shows to the audience;
- a build step forward or back on the live slide;
- **Clear All** (button, ⇧Esc, F1, the Local API's and phone remote's clear,
  macros);
- the switch again.

Firing something cuts from black to it, with no transition: the transition
engines still hold what was blacked out, and a dissolve would show it on
its way out. `ServiceControls.apply()` sets every layer's next transition to
a cut and takes the cover off only after the new scenes are pushed.

These leave it on: Clear Slides / Media / Alerts / one layer, firing music, a
message to the stage alone, and editing the live slide.

It is not saved: a relaunch starts with it off.

## Where it lives

- `ShowState.isBlack` (SlideScene) holds the flag and says what clears it. It is
  not part of `ShowState.scene()`, because the stage's Audience mode mirrors
  that scene and must keep showing it.
- `ServiceControls.isBlack / setBlack / toggleBlack` wrap it, and `apply()`
  hands it to `OutputManager.setBlack` on every pass, so a fire that ends
  Black reaches the outputs without each fire path knowing.
- `OutputManager.provider(for:)` swaps the scene for `RenderScene.blackedOut()`
  (RenderEngine) for every screen whose role isn't Confidence. The stage
  plan's picture of the audience screen asks for
  `previewProvider(for:ignoringBlack: true)`, so it skips the cover. It is a drawn
  full-canvas item, not the scene background: the livestream output clears to
  transparent and skips the background.
- `BlackBar` in `MonitorsPanel.swift` is the button. It is not gated for
  run-only volunteers, like Clear All; the key is in `KeyCommand.runsInRunOnly`.

Tests: `BlackScreenTests` (SlideScene), `BlackCoverTests` (RenderEngine),
`BlackRoutingTests` (OutputEngine).
