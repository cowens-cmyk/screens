# Before Service stage

The stage display's Before Service layout is one large countdown to a service's
start: "SERVICE STARTS IN" over m:ss (h:mm:ss over an hour). Nothing else is
on it.

## When the stage is on it

`BeforeServiceStage.applies` (PresenterCore), called from
`ServiceControls.followBeforeService` each time a slide goes live, with Stage
follows items on and no own stage layout on the presentation:

- the walk-in slideshow, however it goes up (plan item with `isPreService`,
  Service Day's pre-service presentation, a looping deck named for walk-in);
- the walkout: a plan item with `isWalkout` (every slide of it), or Service
  Day's walkout presentation put up on its own;
- the plan's last presentation on its last slide (not a sermon).

The countdown video is neither: it is a video that plays once, so the Video
layout shows over the stage's mode while it plays (its time left is the time to
the service). The stage tags (`docs/stage-stream-tags.md`) say the same.

## What it counts to

The `Until Service` Service Tracking timer
(`service_tracking.untilService.remaining`). `SermonTimerAutoReset` works out
today's services every minute (the plan's Shepherd times, else Schedule
Service, else the Service Day setup, never mixed) and every 5 seconds picks
`ServiceStartClock.target`, stored on `ServiceControls.stageServiceTime`;
`ServiceTimingController` builds the timer from it.

- Walk-in: the next service still to come, at its service time (not the
  countdown's start). It reads the wall clock, so it needs nothing from the
  countdown video.
- Walkout: the same rule, so the next service today if there is one.
- A service that started under ten minutes ago stays the target and reads 0:00
  (a walk-in running late), never negative and not the time to a later
  service. Services last longer than that, so by the walkout the next one shows.
- Nothing left today: the timer is stopped, and the layout shows "TIME" and the
  clock instead (its objects carry visibility conditions on the timer's
  running state).

## Existing libraries

The layout is the library document `screens.stage.preservice`. Built-in
default: `ConfidenceLayoutTemplate.preService`. A copy still exactly as the old
design made it (two timers and the clock) is replaced once at launch
(`ConfidenceMonitorController.upgradePreServiceLayoutIfUntouched`, like the
Worship and Message layouts); a copy anybody changed is left alone and keeps
reading the timers it has (Until Countdown and Until Service still exist).
Libraries with no such document use the template.
