---
id: 3
title: "How can it read Gmail, Google Sheets and notes?"
labels: [wayfinder:research]
status: closed
assignee:
parent: 1
blocked_by: []
---

## Question

What are the realistic ways to read (and later write) Gmail, Google Sheets and notes (Apple Notes or Google Keep/Docs, whichever Dara uses)? Compare Google APIs with OAuth, existing MCP connectors and Claude connectors, and AppleScript or local DBs. Cover setup effort, limits, and whether they can run unattended.

## Comments

### 2026-10-10 — research agent

- **Gmail and Sheets:** use one Google OAuth client of our own (desktop, loopback + PKCE). Set it to In Production and leave it unverified under the personal-use exemption, because "Testing" refresh tokens die after 7 days.
- **Gmail in v1:** `gmail.readonly`, polling `history.list`. **Sheets in v1:** `spreadsheets.readonly` on sheets Dara registers.
- **Notes app still unconfirmed:**
  - Apple Notes: AppleScript/JXA (one Automation prompt), which works unattended while logged in.
  - Google Docs: the same OAuth client.
  - Google Keep: no API path for a personal account (the Keep API is for Workspace admins only).
- **Claude connectors and Google's remote MCP servers** (Developer Preview) suit the interactive Acting layer, not the background importer.
- **Findings:** `research/gmail-sheets-notes-access.md` on branch `research/gmail-sheets-notes-access`.
