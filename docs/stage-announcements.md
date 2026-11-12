# Announcements stage

The stage display's Announcements layout (`ConfidenceLayoutTemplate.announcements`,
id `screens.stage.announcements`) shows what the room sees in a box named
**Audience**, with the announcements' time left and the clock under it.

- **When.** A presentation whose type is Announcements going live sets
  `ShowSetup.stageMode` to `.announcements` (`ServiceControls.applyScreenDefaults`,
  with Stage follows items on and no stage layout of its own). A song or the
  message sets its own mode; any other presentation after it goes back to Worship.
- **The 90 seconds.** `AnnouncementsTimer` (`screens.timer.announcements`) is
  set to 90 seconds and started from the top each time the announcements go
  live. It counts past 0:00 in red.
- **The room.** `StageScenes` lays the whole audience scene, every layer, into
  any layout's shape named Audience (`audienceBoxName`), over the box's fill.
  The rest of the layout is built and cached as usual.
- **Videos.** While the stage is on Announcements or Before Service from a
  slide, `ShowSetup.stageHoldsThroughVideos` keeps the Video layout out of the
  stage plan, so a logo or welcome video doesn't take the stage. The plan's
  countdown, and a video put up outside the announcements, clear it.
- **Tags.** Type Announcements reads "Announcements" (docs/stage-stream-tags.md,
  rule 3a), in the CMS too.
