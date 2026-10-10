---
id: 2
title: "Which macOS activity signals can we read?"
labels: [wayfinder:research]
status: closed
assignee:
parent: 1
blocked_by: []
---

## Question

Which signals can a local process on macOS read cheaply and reliably to work out **Now**? Cover the active app and window title, browser tab URL and title (Chrome/Safari), VS Code / Rider open project and file, git branch and recent commits, Calendar events, and idle time. For each one: the API or mechanism, the permission it needs (Accessibility, Screen Recording, Automation), how fast it is, and the battery/CPU cost. Also cover the cost and latency of an occasional screenshot sent to the Claude API.

## Comments

### 2026-10-10 — research agent

- Minimal always-on set: active app (NSWorkspace notification, no permission), focused window title (Accessibility AX observer), Calendar (EventKit full access), idle time (CGEventSource, no permission).
- Window titles need **Accessibility**, not Screen Recording. Set VS Code `window.title` to include the full path and branch so that the title carries project, file and branch.
- Browser URL comes via Apple Events when a browser activates (Automation grant per browser). Git comes from `.git/HEAD` plus the reflog, watched with FSEvents. Both are event-triggered.
- Screenshot fallback: ScreenCaptureKit window capture (Screen Recording), ~1.3–2.7k tokens per image, ~$0.002 per shot on Haiku 4.5, ~1–4 s round-trip.
- Findings: `research/macos-activity-signals.md` on branch `research/macos-activity-signals`.
