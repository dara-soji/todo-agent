# Personal work assistant

A Mac assistant that knows what its one user is working on and says what comes next.

## Language

**Now**:
The single piece of work the user is doing at this moment, inferred from Signals and resolved to a Project and, where possible, a Task.
_Avoid_: current task, focus

**Next**:
The one task the assistant recommends after Now. There is always exactly one Next.
_Avoid_: up next, queue

**Task**:
A unit of work in the assistant's own list, with a source it came from.
_Avoid_: todo, item, ticket

**Source**:
Where a Task originated: email, notes, a Google Sheet, code work, or added by hand.

**Suggestion**:
A candidate Task found in a Source that waits for the user to accept or dismiss it. Accepting turns it into a Task.
_Avoid_: inbox item, pending task

**Project**:
An ongoing body of work (a repo, a course, a sheet the user keeps) that Signals can be matched to. A Task may belong to one Project.
_Avoid_: tag, area, context

**Committed Task**:
The Task the user has accepted as what they are doing now, usually by accepting Next. Drift is measured against it.
_Avoid_: active task, current task

**Signal**:
One observable piece of evidence about what the user is doing (active app, window title, calendar event, screenshot).

**Drift**:
When Now has matched a different Project, or no Project, for longer than a short grace period while there is a Committed Task.

**Nudge**:
A light prompt the assistant shows when it detects Drift.

**Guardrail**:
A rule deciding whether an action runs on its own or must ask the user first.
