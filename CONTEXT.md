# Personal work assistant

A Mac assistant that knows what its one user is working on and says what comes next.

## Language

**Now**:
The single piece of work the user is doing at this moment, as inferred from activity signals.
_Avoid_: current task, focus

**Next**:
The one task the assistant recommends after Now. There is always exactly one Next.
_Avoid_: up next, queue

**Task**:
A unit of work in the assistant's own list, with a source it came from.
_Avoid_: todo, item, ticket

**Source**:
Where a Task originated: email, notes, a Google Sheet, code work, or added by hand.

**Signal**:
One observable piece of evidence about what the user is doing (active app, window title, calendar event, screenshot).

**Drift**:
When Now no longer matches the Task the user committed to.

**Nudge**:
A light prompt the assistant shows when it detects Drift.

**Guardrail**:
A rule deciding whether an action runs on its own or must ask the user first.
