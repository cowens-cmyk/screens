# Announcements stage

The stage display's Announcements layout (`ConfidenceLayoutTemplate.announcements`,
id `screens.stage.announcements`) shows what the room sees in a box named
**Audience**, with the announcements' time left and the clock under it.

- **When.** A presentation whose type is Announcements going live sets
  `ShowSetup.stageMode` to `.announcements` (`ServiceControls.applyScreenDefaults`,
  with Stage follows items on and no stage layout of its own). A song or the
  message sets its own mode; any other presentation or plan video after it
  goes back to Worship, also one with a stage layout of its own.
- **The 90 seconds.** `AnnouncementsTimer` (`screens.timer.announcements`) is
  set to 90 seconds and started from the top each time the announcements go
  live. It counts past 0:00 in red.
- **The room.** A shape named Audience (`audienceBoxName`) is filled in on each
  Mac with that Mac's audience screen (`ConfidenceLayout.showingAudience`, a
  screen-source fill at `.fit`), where `ConfidenceMonitorController` copies
  layouts to the render thread. It is the screen's own picture through
  `ScreenMirrorService`, so text, builds and videos are exactly what the room
  sees. Which screen that is differs per Mac, so the document only names the
  box. The mirror runs only while a layout with the box is up.
- **Videos.** `ShowSetup.stageHoldsThroughVideos` keeps the Video layout out of
  the stage plan while an Announcements deck is up on the Announcements stage,
  or the walk-in slideshow on Before Service (`holdsStageThroughVideos`). The
  walkout and the plan's closing video are on Before Service too and still
  show as videos. A plan video item always clears it (and ends the
  announcements); a video fired by hand clears it outside the announcements.
- **Tags.** Type Announcements reads "Announcements" (docs/stage-stream-tags.md,
  rule 3a), in the CMS too.
