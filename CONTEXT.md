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

**Triage**:
The assistant's sorting of each incoming email into exactly one of Action, Worth knowing, or Noise.

**Action email**:
An email asking the user to do, reply to, or decide something, or carrying a deadline. Becomes a Suggestion.
_Avoid_: important email, urgent email

**Worth knowing**:
An email the user should see but need not act on. Shown as a line in the Digest, never a Suggestion.
_Avoid_: FYI, info email

**Noise**:
An email Triage drops silently.

**Digest**:
The list of Worth-knowing lines the assistant shows alongside Now/Next.

**VIP**:
A sender whose mail is never dropped as bulk mail, either listed by the user or someone the user has recently emailed. A VIP's mail is still triaged.

**Project**:
An ongoing body of work (a repo, a course, a sheet the user keeps) that Signals can be matched to through its Matchers. A Project is declared by the user or proposed by the assistant and accepted by the user. A Project is either active or archived, and an archived Project matches nothing. Projects do not nest. A Task may belong to one Project.
_Avoid_: tag, area, context

**Matcher**:
A rule saying that a Signal belongs to a Project: a repo path, a Sheet, a URL prefix, or a calendar keyword. A Matcher on an email sender or thread assigns a Suggestion's Project but never sets Now. When several Matchers fit, the most specific one wins.
_Avoid_: rule, mapping, filter

**Neutral**:
An app or site used across all work (Terminal outside a repo, chat, search, reference docs). A Neutral Signal leaves Now on the last matched Project for a short while instead of counting as no Project.
_Avoid_: ignored, generic

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
The rule placing each Operation in one tier (Auto, Ask or Never). The helper enforces it, whoever starts the Operation.

**Operation**:
Anything the assistant does that changes state, in its own task store or outside it (a Task edit, opening a file, drafting or sending an email).
_Avoid_: action (taken by Action email), command

**Auto**:
The tier for an Operation that runs without asking: it is private to the user, undoable, and invisible to anyone else.

**Ask**:
The tier for an Operation that waits for the user to confirm it in the menu bar. An unanswered Ask expires and does not run.
_Avoid_: approval, prompt

**Never**:
The tier for an Operation the assistant does not perform at all: money, credentials, system or security settings, permanent deletion, anything inside an Excluded app.

**Excluded**:
An app, site, email sender or notes folder the assistant must not read or send anywhere. Private-browsing windows, secure text fields and system password prompts are always Excluded. Excluded time counts as Neutral.
_Avoid_: blocked, private, ignored

**Operation log**:
The local record of every Operation: its tier, who started it, whether it was confirmed, and how to undo it.
_Avoid_: audit log (that is the API audit log), history

**Now history**:
The local record of Now as Project-level time blocks, with no window titles or URLs.
_Avoid_: timesheet, activity log
