# Scheduler schedules

The Scheduler's **New Schedule…** sheet (`apps/mac/Sources/PlanScheduleSheet.swift`)
makes an ordinary `ScheduleTrigger` from a simple form: what plays, and when.
The engine, History, snooze, end dates and folders treat it like any other
trigger. The logic is in `PresenterCore/Library/PlanSchedule.swift` and is
tested in `PlanScheduleTests`.

## When

One condition per schedule:

| Repeats | Condition |
| --- | --- |
| Never | `oneTime`, `date` = start day + time |
| Every day | `weekly`, all seven days, `startDate` |
| Weekly | `weekly`, the chosen `days`, `startDate`, `intervalWeeks` when more than 1 |

`startDate` ("2026-11-15") and `intervalWeeks` are optional fields on
`ScheduleCondition`. `ScheduleMath` fires nothing before the start day, and
for an interval it counts whole Sunday-to-Saturday weeks from the start day's
week, so "every 2 weeks on Sunday and Wednesday" keeps both days in the same
week. A weekly condition without them behaves as before.

**Ends** writes the trigger's existing `enabledUntil` as the end day's last
second (`2026-12-31T23:59:59`), or nothing for **Never**. After the last run,
the trigger is archived to History as any ended trigger is.

## What

- **A presentation**: `firePresentation` from slide 1.
- **One plan**: `fireServiceItem` with `serviceId` and `serviceItemId`, as the
  Schedule Service countdowns already use.
- **Each week's plan**: `fireServiceItem` with `planSeries`. It is set to the
  service type ("Sunday Morning Worship") for a series of Shepherd plans. For
  a template, `serviceId` is the template and `planSeries` is the template's
  service type, or "" when it has none.

A plan's item has a new id in each week's plan, so the action also carries
what the item is: `serviceItemRole` (countdown, preService, transition,
walkout), `serviceItemName`, and `serviceItemRefId` (the presentation or video
it plays). All four fields are optional on `SlideAction`.

## Firing

When the trigger fires, `SchedulerController.fireNow` resolves every
`fireServiceItem` action through `AppModel.resolvePlanItem`
(`PlanSchedule.resolve`):

1. **The plan.** A single plan is itself. A series takes the non-template plan
   dated today whose `mxuServiceTypeName` matches (the open plan if two
   match). A template without a type takes the plan named like it, else the
   day's only plan. **Run Now** takes the next plan when there's none today.
2. **The item.** It matches the same id first (one plan, or the template),
   then the role, then the same linked presentation or video, then the name.
3. **The content.** An item with nothing linked (a week's countdown with no
   video chosen yet) plays the action's `serviceItemRefId` in that item's
   place. The plan still moves on after it.

The action is then pinned to that plan and item (`PlanSchedule.pinned`) and
goes to `ActionRouter`, which brings the plan up and calls
`ServiceControls.fireServiceItem`. If either step can't resolve, the whole
trigger is skipped before anything is cleared. History records the reason.

Triggers that play a plan item fire only on the Mac that runs the service
(`ServiceDay.firesOnlyOnServiceMac`). One whose item is a pre-service
slideshow goes through `PreServiceGuard`, like the Service Day restarts.

## Editing

The sheet opens for any trigger with one `weekly` or `oneTime` condition and
one `firePresentation` or `fireServiceItem` action, with or without a
`clearAll` first (`PlanScheduleSheet.canEdit`). The Service Day restarts and
the Schedule Service countdowns are excluded, because their own setups
rewrite them. Anything else stays in the full trigger editor. The editor
shows an interval or start date set in the sheet as a caption.
