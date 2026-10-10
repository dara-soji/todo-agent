---
id: 4
title: "What can Claude-native vs standalone builds do?"
labels: [wayfinder:research]
status: closed
assignee:
parent: 1
blocked_by: []
---

## Question

Compare two ways to build the assistant. (a) Claude-native: Claude Code / Agent SDK with skills, scheduled tasks, computer-use, MCP servers and memory, plus a small menu-bar helper. (b) Standalone: a Mac app (Swift or Electron/Tauri) running its own agent loop on the Claude API. For each: what it can do out of the box, how it runs in the background all day, an estimated cost per day of continuous awareness, and the effort to get a working v1.

## Comments

### 2026-10-10 — research agent

Findings are in `research/build-options.md` on branch `research/build-options`.
- You need a local Mac helper either way. Claude Code can't read the frontmost app or window title in the background, and it can't draw a menu-bar item.
- Claude Code scheduling (`/loop`, Desktop tasks, routines) suits work every few minutes to hours. Per-minute awareness inside it costs about $1.70–$8/day on Opus 5.5, and each fire carries the full session context.
- A small direct Messages API check on Haiku 5.5 does the same awareness job for about $0.04–$0.08/day. Planning Next on Sonnet 5.5 adds about $0.27/day.
- Effort to v1, part-time: Claude-native about 1–2 weeks, standalone about 4–6 weeks, hybrid about 2–3 weeks.
- Leaning hybrid: a native helper handles sensing, the Haiku check, the menu bar and the task store, and exposes them over MCP. Claude Code runs skills and connectors for planning and imports, and later computer use. The decision is left to ticket 0007.
