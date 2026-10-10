---
id: 8
title: "How should Now/Next and the Nudge look and feel?"
labels: [wayfinder:prototype]
status: closed
assignee: dara
parent: 1
blocked_by: [5]
---

## Question
Build a rough, clickable menu-bar mock of the **Now / Next** display and a **Nudge** on **Drift**. React to it: how much text, how often it nudges, how Dara accepts, skips or snoozes Next, and how Dara adds an ad-hoc Task quickly.

## Comments

### 2026-10-10 — dara (from *How are Projects defined and matched to Signals?*)

Include in the mock: a "Not this → [Project / Neutral / None]" correction on Now, with its follow-up "Always match <repo/URL> to X?"; a "Mark app/site as Neutral" action; how a proposed Project ("New Project: <name>? [Add] [Dismiss]") appears; and how an unconfirmed Haiku guess for an unmatched window looks next to a confident match.

### 2026-10-10 — dara (prototype)

**Resolution.** Prototype kept on branch `prototype/now-next-surface` (`prototypes/now-next-surface/index.html`): commit `fcc20ba` has the three variants (rich popover, native menu, floating HUD), and `378a21d` has the chosen surface.

- **Menu bar (from the native-menu variant):** a square Project dot and the Project's short name in caps. A hollow dashed dot plus "?" means a Haiku guess. An amber ● means prompts are waiting, and an amber ▲ means Drift.
- **Dropdown:** a native-style menu with submenus, top to bottom: prompts (Always match?, proposed Project, "Is this X?", New task?, skipped 3×); then **Now** (Committed Task, Project with evidence, Mark done, Not this ▸ [Projects / Neutral / None], Treat <app/site> as Neutral); then **Next** (title in amber, one-line reason, Start, Skip, Snooze ▸ 1 hour / Till tomorrow / Waiting on someone); then Add task… (⌥Space), Suggestions ▸, Worth knowing ▸. Prompts collect in the menu and never pop up on their own.
- **Quick-add:** a ⌥Space palette. ↩ adds the Task to Now's Project and ⌘↩ adds it and starts it (it becomes the Committed Task and the old one becomes "resume"). A confirmation panel offers Start now / Undo.
- **Nudge (from the floating-HUD variant):** a panel above the Dock, bottom right, that appears only on Drift: "<where you are> ≠ <committed Project>", the window, and the Committed Task. Buttons: Back to it, Switch task, It's related (a Not this correction to the committed Project), Quiet 30m. It doesn't take over the menu-bar title.
- **Drift threshold:** 5 minutes. Only a confident Project (a Matcher, a held Neutral or a correction) counts toward Drift. A Haiku guess never does, so a wrong guess can't nudge Dara while on-task. The Nudge fires once per Drift episode and re-arms only after Dara is back on the Committed Project. There is no repeat nudge while still drifting.
- **Skip:** Skip demotes the Task out of Next for 2 hours. On the 3rd skip, a prompt asks "Snooze till tomorrow / Drop it / Keep it". Snooze "Waiting on someone" has no wake time. When nothing is open, Next shows "Review Suggestions (n)" or "Plan tomorrow".
- **Interruptions:** after 10 minutes on no Project, the menu offers "New task: <window title>?" with **Add** (adds it, commits it, and remembers the interrupted Task) or **It's a quick one** (no Task). Once that's done, Next is "Back to what you were doing before the interruption".
- **Corrections, Neutral, guesses:** Not this fixes Now for the current window at once. For anything except None, it then asks "Always match <key> to X?" / "Always treat <key> as Neutral?" with **Always / Just this once**. "Treat <app/site> as Neutral" applies straight away and shows only when the window isn't already Neutral. A proposed Project shows "Seen on 2 days: <key>", and Add creates it with that Matcher. A guess shows "· guess" in the dropdown and "Is this <Project>? [Yes] [No, it's…]"; Yes counts as a correction, so it offers Always. A confident match shows its evidence ("Matched by ~/code/todo-agent").
- **Visual theme:** follows Dara's reference board, with no deviation. Palette `#0D0F10` / `#303B35` / `#6B706D` / `#A8ADAA` / `#E8ECE9`, accent `#FFA500`; Tektur for display and titles, JetBrains Mono for uppercase, wide-tracked labels and metadata; chamfered (cut-corner) panels and buttons; HUD-style thin rules.

