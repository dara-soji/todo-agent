---
id: 10
title: "How are Projects defined and matched to Signals?"
labels: [wayfinder:grilling]
status: closed
assignee: dara
parent: 1
blocked_by: []
---

## Question
Now resolves Signals → **Project** → Task, so the Project mapping decides how good awareness is. How does a Project come to exist: Dara declares it, the assistant proposes one from repos, Sheets and calendar it sees, or both? Which Signals map to a Project (repo path, VS Code workspace, browser domain, Sheet id, calendar keyword, email sender or thread), and what happens when Signals match two Projects or none? Is the .NET course a Project?

## Comments

### 2026-10-10 — dara (grilling session)

**Resolution.** Glossary terms added to `CONTEXT.md`: **Matcher** and **Neutral**. **Project** was sharpened (declared or proposed, active/archived, flat).

- **Creation:** both declared and proposed. At setup the assistant proposes Projects from repos under the code folder and from registered Sheets, and Dara prunes the list once. After that it proposes a new Project only when the same unmatched Signal recurs on 2+ separate days. Every proposal needs one click to accept, and nothing is created silently.
- **Matchers:** repo path (also covers the VS Code workspace via the window title, and the Terminal's working directory), Sheet id, URL prefix (never a bare domain like `github.com`) and calendar keyword. These set Now. Email sender/thread Matchers only assign a Suggestion's Project, never Now.
- **Neutral:** apps and sites used across all work (Terminal outside a repo, Slack, Claude, search, Stack Overflow, reference docs) keep Now on the last matched Project for ~15 min, then count as no Project. There's a short default list, and Dara can mark more as Neutral from the menu.
- **Two or more matches:** (1) the foreground window beats the calendar (in a meeting, Zoom is Neutral, so the calendar event decides); (2) the most specific Matcher wins (longest path/URL prefix); (3) if still tied, the Committed Task's Project; (4) otherwise, the most recently matched Project. A tie alone never triggers a screenshot.
- **No match:** Now shows "No Project", which feeds Drift and the "New task?" prompt as decided in *How are Tasks shaped, and how is Next chosen?*. After ~2 min of a stable unmatched app+title, the assistant takes one screenshot and asks Haiku "which Project, or none?", caching the answer per app+title. The result is shown as a guess and never saved as a Matcher without Dara's click.
- **Corrections:** "Not this → [Project / Neutral / None]" from the menu bar fixes Now immediately and offers a one-click "Always match <repo/URL> to X?" Matcher. There's no silent learning.
- **.NET course:** one Project, "Learning .NET". Its Matchers are the exercise folder(s) as repo paths and `learn.microsoft.com/*/training/` as a URL prefix. The rest of `learn.microsoft.com` (API/reference docs) is Neutral, and the most-specific rule settles the overlap. Any special handling for learning stays in the *Learning support* fog.
- **Lifecycle:** flat, with no sub-projects in v1. Status is `active` or `archived`; archived Projects stop matching, and their Tasks keep the Project for history. The assistant suggests archiving after 30 days with no matched Signals.
