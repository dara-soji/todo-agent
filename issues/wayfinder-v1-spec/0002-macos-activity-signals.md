---
id: 2
title: "Which macOS activity signals can we read?"
labels: [wayfinder:research]
status: open
assignee:
parent: 1
blocked_by: []
---

## Question

Which signals can a local process on macOS read cheaply and reliably to work out **Now**? Cover the active app and window title, browser tab URL and title (Chrome/Safari), VS Code / Rider open project and file, git branch and recent commits, Calendar events, and idle time. For each one: the API or mechanism, the permission it needs (Accessibility, Screen Recording, Automation), how fast it is, and the battery/CPU cost. Also cover the cost and latency of an occasional screenshot sent to the Claude API.
