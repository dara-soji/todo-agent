---
id: 7
title: "Pick the build platform"
labels: [wayfinder:grilling]
status: closed
assignee: dara
parent: 1
blocked_by: [2, 3, 4]
---

## Question
Using the findings from the three research tickets, decide: Claude-native setup, standalone app, or a hybrid? Choose the language and runtime for any local component, and decide where Tasks are stored.

## Comments

### 2026-10-10 — dara (grilling session)

**Resolution.** Recorded in ADR `docs/adr/0001-hybrid-helper-owns-state.md`. No glossary changes.

- **Shape:** hybrid. An always-on native **helper** plus **Claude Code** as the conversational layer.
- **Helper:** Swift, built locally in Xcode, set as a login item, macOS 14 or later, not notarized. It owns:
  - sensing, with the exclude list applied before anything leaves the Mac;
  - the Haiku 5.5 awareness check that works out Now and Drift;
  - **Next**, chosen by the rule filter and score with a Sonnet 5.5 tie-break;
  - **background imports and Triage**: its own Google OAuth client polls Gmail `history.list` and registered Sheets, AppleScript reads Apple Notes, and Haiku sorts emails and extracts Suggestions;
  - the menu-bar Now/Next and Nudges.
- **Task storage:** SQLite in `~/Library/Application Support/`, written only by the helper.
- **Seam:** the helper runs a local MCP server (Streamable HTTP on `127.0.0.1`, token-protected, built on the Swift MCP SDK). Claude Code reaches the store only through it, never the database file.
- **Claude Code in v1:** conversation only, with no background or scheduled work. That covers "plan my day," reviewing and bulk-editing Tasks, and asking about Projects, with Google connectors for interactive lookups.
- **Billing:** an API key only, for both the helper and Claude Code; no Pro/Max plan. The API key and Google tokens are stored in the Keychain. Expected cost is about $0.35/day for the helper plus conversations.
- **Deferred:** screen control for the Acting layer. Claude Code's computer use needs Pro or Max, so later the choice is to subscribe or to have the helper drive the Mac via the API's computer-use tool. v1 depends on neither.
