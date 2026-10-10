---
id: 9
title: "Which actions fall into which Guardrail tier?"
labels: [wayfinder:grilling]
status: closed
assignee: dara
parent: 1
blocked_by: []
---

## Question
Make the autonomy rule concrete. List the likely actions (open app or project, create a Task, edit a Sheet, file a note, draft or send email, run code commands, delete things) and assign each to *runs on its own*, *asks first*, or *never*. Also settle the privacy exclude list (it also keeps those senders' email out of Triage's API calls; see *What makes an email important?*) and what gets logged.

## Comments

### 2026-10-10 — dara (grilling session)

**Resolution.** Recorded in ADR `docs/adr/0002-helper-enforces-guardrails.md`. Glossary: added **Operation**, **Auto / Ask / Never**, **Excluded**, **Operation log**, **Now history**; tightened **Guardrail**.

- **Auto test:** an Operation is Auto only if it is local or private to Dara, undoable, and invisible to others. Otherwise it is Ask. **Never** covers money, credentials, system or security settings, permanent deletion, and acting inside Excluded apps.
- **Enforcement:** the helper enforces tiers inside its MCP tools. An Ask returns "pending" to the caller, and Dara confirms in the menu bar, whoever started it. Claude Code's allow-list can't skip it.
- **Pending Asks:** expire after 30 minutes, or when the conversation that started them ends, and are logged as "expired, not run". Several Asks from one request appear as one confirm.
- **Changing tiers:** Dara may make any Operation stricter. Ask → Auto only for narrowly scoped cases (one Operation type, optionally one Project or Sheet), and each loosening is logged. Never can't be changed.
- **v1 Operations (own data):**
  - Auto: Task create, edit, complete; accept or dismiss a Suggestion; Commit, snooze, skip Next; soft delete (Deleted list, undoable, purged after 30 days); Project and Matcher changes Dara asked for; adding an exclusion.
  - Ask: bulk edits of more than 5 Tasks (with a preview); Projects and Matchers the assistant proposes; removing an exclusion.
- **Acting layer (later):**
  - Auto: open an app, Project repo or folder, file or URL; create an Apple Note or append to one the assistant made; draft an email reply in Gmail Drafts (needs `gmail.compose`); a calendar event with no invitees.
  - Ask: edit or move Dara's own notes; send any email, reply, invite or message; edit a Google Sheet; an event with invitees; delete or archive to Trash; post publicly. Every screen-control run is Ask with a stated goal, each step inside it is still tiered, it is Never in Excluded apps, and it aborts if one comes to the front.
  - Never: empty trash or permanent delete; pay, buy or move money; enter passwords or keys; change system or security settings.
- **No shell in the helper:** the helper runs no commands. Git is read via FSEvents. Code work stays in Claude Code under its own permissions.
- **Exclude list:** starts empty. Setup offers detected password managers and banking apps unticked, and the menu bar has an "Exclude this app or site" item. These are always on and can't be removed: private-browsing windows, secure text fields, system password prompts. For an Excluded app or site, nothing is read or sent: no title, URL, screenshot or body. Only "Excluded" and the time are recorded, and that time counts as Neutral for Now and Drift. Excluded email senders never reach Triage's API calls.
- **Logs (local SQLite):**
  - Operation log: every Operation with tier, who started it (helper, Claude Code, Dara), whether it was confirmed, and undo data. 90 days, viewable from the menu bar.
  - API audit log: metadata only (time, purpose, model, tokens, cost, kind of content sent), never content. 30 days. Doubles as the cost meter.
  - Now history: Project-level time blocks only (Project, Committed Task, start, end), with no titles or URLs. 90 days. Features built on it (timesheet, weekly summary, review) are left to the map's History and Daily rhythm items.
