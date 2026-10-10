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

- [Which macOS activity signals can we read?](wayfinder-v1-spec/0002-macos-activity-signals.md): Always on: active app (no permission), window title via Accessibility (VS Code title set to show path and branch), EventKit calendar and idle time. Browser URL (Automation) and git (FSEvents) are read on events. ScreenCaptureKit window screenshots (~$0.002 each on Haiku) only when unsure.
- [How can it read Gmail, Google Sheets and notes?](wayfinder-v1-spec/0003-gmail-sheets-notes-access.md): own Google OAuth desktop client (In Production, personal-use unverified) polling Gmail `readonly` + Sheets `readonly` in the background; Apple Notes via AppleScript, Keep has no consumer API; Claude connectors/Google MCP only for interactive use. Notes app still to confirm.
- [What can Claude-native vs standalone builds do?](wayfinder-v1-spec/0004-build-options.md): You need a native helper either way, since Claude Code can't sense the frontmost app or draw a menu bar. Per-minute awareness on Haiku 5.5 via the API costs about $0.05/day, versus about $2–8/day inside Claude Code on Opus. Leaning hybrid (helper + MCP + Claude Code skills), to be decided in 0007.
- [How are Tasks shaped, and how is Next chosen?](wayfinder-v1-spec/0005-task-model-and-next.md): first-class Projects map Signals to work; by-hand and code Tasks are direct, while email, Sheets and notes become one-click Suggestions (7-day expiry). Next = calendar-gap and deadline filters + score, AI tie-break with a reason, never empty. Accepting Next commits; Drift after ~5 min; interrupts over ~10 min prompt "New task?"

## Not yet specified

- **Acting layer**: which concrete actions it takes first (opening project and files, filing notes, editing Sheets, drafting email replies) and how Dara "points it at things". This depends on the platform and on the guardrails.
- **Voice**: whether to support push-to-talk or a wake word, local or cloud speech-to-text, and how voice commands map to actions.
- **Learning support**: whether the .NET/C# learning gets special handling (a study plan, progress tracking, "next lesson" as a Next) or is just ordinary tasks.
- **Daily rhythm**: morning plan and end-of-day review (including expiring Suggestions and "Plan tomorrow").
- **History**: whether it keeps a log of what Dara worked on (a timesheet or weekly summary), and for how long.

## Out of scope

- Multiple users, accounts, other platforms (Windows, mobile), or distributing or selling the app.
