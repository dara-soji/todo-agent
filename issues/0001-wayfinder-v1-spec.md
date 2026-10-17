---
id: 1
title: "Map: personal work assistant — v1 spec"
labels: [wayfinder:map]
status: closed
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
- [What makes an email important?](wayfinder-v1-spec/0006-email-importance.md): Inbox emails go through rules and then Haiku, which sorts each one as Action → Suggestion (one per thread, guessed deadline applied only on accept), Worth knowing → menu-bar Digest (clears on read or after 24h), or Noise. VIP list plus recent correspondents; notifications only for a VIP Action due today or tomorrow. Corrections are explicit only.
- [Pick the build platform](wayfinder-v1-spec/0007-build-platform.md): hybrid. An always-on Swift menu-bar helper owns sensing, Now/Next (Haiku awareness, Sonnet tie-break), background Gmail/Sheets/Notes imports and Triage, and a SQLite task store it alone writes. Claude Code is conversation only and reaches the store via the helper's local MCP server. API key only. ADR `docs/adr/0001-hybrid-helper-owns-state.md`.
- [How are Projects defined and matched to Signals?](wayfinder-v1-spec/0010-project-definition.md): Projects are declared, or proposed and then accepted (at setup from repos and Sheets, later from unmatched Signals recurring 2+ days). They are flat, active/archived. Matchers are repo path, Sheet id, URL prefix and calendar keyword; email Matchers only file Suggestions. Neutral apps keep the last Project for ~15 min. Conflicts: foreground > calendar > most specific > Committed Project > most recent. Unmatched for 2 min → one cached Haiku screenshot guess. "Not this →" corrections offer a Matcher. Learning .NET is a Project (MS Learn `/training/` + exercise folder).
- [Which actions fall into which Guardrail tier?](wayfinder-v1-spec/0009-guardrail-tiers.md): Operations are Auto only if private, undoable and invisible to others; otherwise Ask; Never for money, credentials, system settings, permanent delete and Excluded apps. The helper enforces tiers and shows Ask confirms in the menu bar (30-min expiry); Dara can tighten, or loosen narrowly. The helper runs no shell. Sends, Sheet edits, Trash and every screen-control run are Ask. The exclude list starts empty, but private windows, secure fields and password prompts are always excluded, and Excluded time counts as Neutral. Local logs: Operation log 90d, API audit (metadata only) 30d, Now history as Project time blocks 90d. ADR `docs/adr/0002-helper-enforces-guardrails.md`.
- [How should Now/Next and the Nudge look and feel?](wayfinder-v1-spec/0008-now-next-surface.md): native-style menu-bar dropdown (Project dot + short name; prompts, Now, Next with reason + Start/Skip/Snooze ▸, Add task ⌥Space, Suggestions, Worth knowing), and a floating Drift panel above the Dock (Back to it / Switch task / It's related / Quiet 30m) after 5 min of confident off-Project time (Haiku guesses don't count), once per episode. Skip demotes for 2h; the 3rd skip asks snooze/drop/keep. Styled to Dara's reference theme: dark/olive/steel palette, `#FFA500` accent, Tektur + JetBrains Mono, chamfered panels. Prototype on `prototype/now-next-surface`.

## Not yet specified

- **Acting layer**: which concrete actions it takes first (opening project and files, filing notes, editing Sheets, drafting email replies) and how Dara "points it at things". This depends on the guardrails. Non-screen actions are helper MCP or API calls. Screen control is open: either add a Pro/Max plan for Claude Code computer use, or have the helper drive the Mac via the API computer-use tool (billing is currently API key only).
- **Voice**: whether to support push-to-talk or a wake word, local or cloud speech-to-text, and how voice commands map to actions.
- **Learning support**: "Learning .NET" is already an ordinary Project (see *How are Projects defined and matched to Signals?*). What remains open is whether it gets special handling (a study plan, progress tracking, "next lesson" as a Next) or is just ordinary tasks.
- **Daily rhythm**: morning plan and end-of-day review (including expiring Suggestions, the email Digest, and "Plan tomorrow"). These are likely Claude Code conversations over the helper's MCP tools.
- **History**: what is recorded is settled (Now history: Project time blocks, 90 days; see *Which actions fall into which Guardrail tier?*). Open: whether it becomes a feature (timesheet, weekly summary) and how that's shown.

## Out of scope

- Multiple users, accounts, other platforms (Windows, mobile), or distributing or selling the app.

## Comments

### 2026-10-17 — dara

**Resolution.** The map reached its destination. Tickets 2–10 closed, the v1 spec was written as issue 11, and v1 was built and merged in 19 slices. *Not yet specified* items (acting layer, voice, learning support, daily rhythm, history) carry forward as candidates for a v2 map.
