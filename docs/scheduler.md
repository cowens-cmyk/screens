# Countdowns

The Schedule tab's **Countdowns** card (`apps/mac/Sources/CountdownScheduleViews.swift`)
plays the countdown at set start times every week, from that day's plan. The
logic is in `PresenterCore/Library/WeeklyCountdown.swift` and
`PlanSchedule.swift`, tested in `WeeklyCountdownTests` and `PlanScheduleTests`.

## The setup

The sheet's fields are the days, every how many weeks, one start time per
service, the plan series, a fallback video, a start day, and an end day or
Never. The setup is not stored in a settings document. It lives in the
triggers it makes: one weekly `ScheduleTrigger` per start time, marked
`weeklycountdown:<n>` in its notes, all with the same rule and action.
`WeeklyCountdown.setup(from:)` reads the setup back from them, and
`WeeklyCountdown.changes` rewrites them in place on save, keeping each one's
on/off state. Each Mac's board files them in a **Countdowns** folder
(`placingWeeklyCountdowns`).

The rule uses two optional `ScheduleCondition` fields:

- `startDate` ("2026-11-15"): `ScheduleMath` fires nothing before that day.
- `intervalWeeks`: whole Sunday-to-Saturday weeks are counted from the start
  day's week.

**Ends** writes the trigger's `enabledUntil` as the end day's last second.

## The action

Every trigger has one `fireServiceItem` action that names a series instead of
a plan. For a Shepherd service type, `planSeries` is the type name. For a
template, `serviceId` is the template and `planSeries` is its type, or ""
when it has none. `serviceItemRole` is `countdown`, and `serviceItemRefId` is
the **If no video** fallback. `PlanSchedule.Source` reads the series back.

## Firing

`SchedulerController.fireNow` resolves the action with
`AppModel.resolvePlanItem` (`PlanSchedule.resolve`):

1. **The plan:** the non-template plan dated today of that service type, or
   the open plan when two share the day. A template without a type matches by
   name, else the day's only plan. **Run Now** takes the next plan when there
   is none today.
2. **The item:** the plan's countdown (`isCountdown`).
3. **The video:** a countdown with no video plays the fallback in that item's
   place.

If any step fails, the trigger is skipped before anything is cleared, and
History gives the reason. A plan given its own countdown with **Start Time…**
(Schedule Service, one-time `countdown:<planID>` triggers) on that day keeps
it, and the weekly one stands aside (`WeeklyCountdown.planHasItsOwn`).
Otherwise the action is pinned to that plan and item, and `ActionRouter` brings
the plan up and plays the item inside it, so the plan moves on when the video
ends. Only the Mac that runs the service plays them
(`ServiceDay.firesOnlyOnServiceMac`).

The same start times give the Before Service stage its service times on a
day with no Shepherd times or Start Time… countdowns: each service begins as
its countdown video ends (`WeeklyCountdown.starts`, see
docs/stage-before-service.md).

## Pre-service restarts retired

The Service Day setup no longer makes pre-service restart triggers.
`SchedulerController` deletes any that sync in from older versions
(`ServiceDay.isRestartTrigger`) and removes the empty Service Day folder.
The setup itself (service times, pre-service slideshow, Transition, Walkout)
is now More › **Service Day…**.
