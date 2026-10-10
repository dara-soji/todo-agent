---
id: 1
title: "Map: personal work assistant — v1 spec"
labels: [wayfinder:map]
status: open
assignee:
---

## Destination

A **v1 spec** for a personal Mac assistant for Dara. The spec is ready to hand to a builder. The assistant always knows what Dara is doing **now**, says what's **next**, and keeps tasks organised from coding, email and notes. Acting on the computer and voice control are specified as later layers with guardrails, not built in v1.

## Notes

- **User and workday**: one user (Dara) on one Mac. The day is coding (currently learning .NET / C#), organising Google Sheets and notes, scanning email for important information, and handling ad-hoc work as it comes up.
- **Settled at charting** (recommendations accepted on 2026-10-10):
  - **Awareness signals**: active app and window title plus the calendar are always on; an AI-read screenshot is taken only when the assistant is unsure.
  - **Surface**: a menu-bar "Now / Next" item, plus a gentle nudge when Dara drifts.
  - **Tasks**: the assistant owns a local task list and imports one way from sources.
  - **Autonomy**: low-risk actions run without asking. Anything that sends, deletes, pays or posts always asks first.
  - **Privacy**: summaries may go to the Claude API. Raw screenshots are never stored. There's an exclude list (banking, password managers).
- **Skills**: grilling tickets call `grilling` + `domain-modeling`; prototype tickets call `prototype`; research tickets call `research`. Use the vocabulary in `CONTEXT.md`.
- **Tracker**: local markdown; see `docs/agents/issue-tracker.md`. Tickets live in `issues/wayfinder-v1-spec/`.

## Decisions so far

<!-- one line per closed ticket -->

## Not yet specified

- **Acting layer**: which concrete actions it takes first (opening project and files, filing notes, editing Sheets, drafting email replies) and how Dara "points it at things". This depends on the platform and on the guardrails.
- **Voice**: whether to support push-to-talk or a wake word, local or cloud speech-to-text, and how voice commands map to actions.
- **Learning support**: whether the .NET/C# learning gets special handling (a study plan, progress tracking, "next lesson" as a Next) or is just ordinary tasks.
- **Daily rhythm**: morning plan, end-of-day review, and how the Next list gets re-planned when ad-hoc work lands.
- **History**: whether it keeps a log of what Dara worked on (a timesheet or weekly summary), and for how long.

## Out of scope

- Multiple users, accounts, other platforms (Windows, mobile), or distributing or selling the app.
