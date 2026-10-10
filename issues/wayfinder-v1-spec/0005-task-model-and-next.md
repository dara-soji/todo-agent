---
id: 5
title: "How are Tasks shaped, and how is Next chosen?"
labels: [wayfinder:grilling]
status: closed
assignee:
parent: 1
blocked_by: []
---

## Question
What fields does a **Task** have (source, effort, deadline, project, status…)? Which **Sources** feed it, and how does a new item become a Task: automatically or confirmed by Dara? And what rule picks **Next**: deadlines, energy, time of day, calendar gaps, continuing the current context? Include how ad-hoc work interrupts the plan.

## Comments

### 2026-10-10 — dara (grilling session)

**Resolution.** Glossary terms added to `CONTEXT.md`: Suggestion, Project, Committed Task (Now and Drift sharpened).

- **Sources (v1):** email, by-hand and code work on by default; Google Sheets opt-in per registered sheet; notes from Apple Notes *(Dara to confirm which notes app is used; Keep would be unsupported)*.
- **Intake:** by-hand and code work become Tasks directly. Email, Sheets and notes become **Suggestions**: one-click accept or dismiss, expiring quietly after 7 days. Dedupe by a per-Source item key (thread id, sheet+row, note id); no cross-Source merging in v1. A Source edit updates the Suggestion or back-link, never a user-set title.
- **Task fields:** title, Source + back-link, status, created, deadline (optional), Project (optional), effort (S/M/L), kind (deep/shallow). Effort and kind are guessed by the assistant and corrected by Dara.
- **Status:** `open`, `committed` (at most one), `done`, `dropped`, `snoozed` (with wake date; "waiting on someone" = snooze + note). Only Dara marks done; the assistant may suggest "done?" on strong evidence.
- **Project:** first-class; maps to Signals (repo path, Sheet, calendar keyword). Now resolves Signals → Project → likeliest Task.
- **Next:** rule picks candidates, AI picks one with a one-line reason. Hard filters: fits the next free calendar block, deadlines first. Score: deadline urgency > continues current Project > deep in the morning / shallow in the afternoon > age. Fallbacks: no Task fits the gap → best Task flagged "won't fit before HH:MM"; no open Tasks → "Review Suggestions" / "Plan tomorrow". Skip demotes that Task for 2h; 3 skips → "snooze or drop?"
- **Commit and Drift:** accepting Next makes it the Committed Task. Drift = more than ~5 min on a different Project or none (threshold tuned in the Now/Next prototype).
- **Ad-hoc interrupts:** more than ~10 min on unplanned work matching no Project → "New task: '<guess>'? [Add] [It's a quick one]". Adding it makes it the Committed Task; afterwards Next offers to resume the interrupted Task first.
