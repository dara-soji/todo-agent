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
- **Drift threshold:** 5 minutes.
- **Visual theme:** follows Dara's reference board, with no deviation. Palette `#0D0F10` / `#303B35` / `#6B706D` / `#A8ADAA` / `#E8ECE9`, accent `#FFA500`; Tektur for display and titles, JetBrains Mono for uppercase, wide-tracked labels and metadata; chamfered (cut-corner) panels and buttons; HUD-style thin rules.

