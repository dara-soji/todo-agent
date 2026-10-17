---
id: 11
title: "Spec: personal work assistant v1 (helper + Now/Next + Tasks + Triage)"
labels: [ready-for-agent]
status: closed
assignee:
blocked_by: []
---

Synthesised from the map *personal work assistant — v1 spec* (issue 1), its closed tickets 2–10, ADRs 0001 and 0002, and the glossary in `CONTEXT.md`. All capitalised terms (Now, Next, Task, Suggestion, Project, Matcher, Neutral, Drift, Nudge, Triage, Guardrail, Operation, Auto/Ask/Never, Excluded …) carry their glossary meaning.

## Problem Statement

Dara works alone on one Mac across very different kinds of work in a day: coding (currently learning .NET / C#), organising Google Sheets and notes, scanning email for what matters, and absorbing ad-hoc work as it lands. There is no single place that knows what Dara is doing right now, what should come next, or which of the things buried in email, notes and Sheets actually need doing. Tasks live in many Sources, important emails get lost among bulk mail, and it is easy to drift off the thing Dara meant to be doing without noticing. Existing to-do apps need constant manual upkeep and know nothing about what is on screen. A general AI assistant that could fill that gap raises cost and privacy worries, and the worry that it might act without asking.

## Solution

A personal assistant made of two parts (ADR 0001):

- An always-on **Swift menu-bar helper** that watches cheap activity Signals (active app, window title, calendar, idle time, plus browser URL and git on events). It resolves them to a **Project** and, where it can, a **Task** to show **Now**. It always shows exactly one **Next** with a one-line reason. It gives a gentle **Nudge** when Dara Drifts from the **Committed Task**. It also imports Gmail, registered Google Sheets and Apple Notes in the background as one-click **Suggestions**, and **Triages** email into Action, Worth knowing and Noise, with a small **Digest**. It owns the local task store and is its only writer.
- **Claude Code** as the conversational layer only ("plan my day", reviewing and bulk-editing Tasks, asking about Projects). It reaches the task store only through the helper's local MCP server.

Every state-changing **Operation**, whoever starts it, passes through the helper's **Guardrail** check (ADR 0002). Auto Operations run. Ask Operations wait for a confirm in the menu bar and expire. Never Operations do not exist. **Excluded** apps, sites, senders and notes folders are never read or sent anywhere. Raw screenshots are never stored. Only summaries and metadata go to the Claude API, and an audit log meters the cost. v1 takes no actions on the computer beyond its own task store. The Acting layer and voice come later.

## User Stories

### Setup and permissions

1. As Dara, I want to build the helper locally in Xcode and run it as a login item on macOS 14+, so that it is always there without needing notarization or distribution.
2. As Dara, I want first-run setup to walk me through each macOS permission (Accessibility, Calendar, Automation per browser, Automation for Notes, Screen Recording) and say why each is needed, so that I grant only what I understand.
3. As Dara, I want the helper to keep working, with less precision, when an optional permission (Screen Recording, browser Automation) is denied, so that one refusal doesn't break the whole assistant.
4. As Dara, I want to enter my Claude API key once and have it kept in the Keychain, so that it is never in a plain file.
5. As Dara, I want to connect my Google account once through the helper's own OAuth client (loopback + PKCE, In Production, unverified personal use) with read-only Gmail and Sheets scopes, so that background imports keep working beyond 7 days.
6. As Dara, I want Google refresh tokens kept in the Keychain, so that they are protected like other credentials.
7. As Dara, I want setup to tell me how to set VS Code's window title to include the full path and branch, so that the window title alone identifies the Project, file and branch.
8. As Dara, I want setup to propose Projects from the repos under my code folder and from my registered Sheets, so that I can prune one list instead of declaring everything by hand.
9. As Dara, I want setup to offer any password managers and banking apps it detects as Exclusions, unticked by default, so that I choose what is Excluded.
10. As Dara, I want to register specific Google Sheets as Sources, so that only the Sheets I choose are read.
11. As Dara, I want to choose which Apple Notes folders are read, or Exclude some, so that private notes stay private.

### Sensing and Now

12. As Dara, I want the helper to always know the active app and focused window title, so that Now updates as I switch work.
13. As Dara, I want the calendar to count as a Signal, so that during a meeting Now reflects the meeting's Project.
14. As Dara, I want the browser URL read when a browser comes to the front, so that web work can match a Project by URL prefix.
15. As Dara, I want git branch and recent commits picked up from file-system events, so that code work is recognised without the helper running any commands.
16. As Dara, I want idle time detected, so that time away from the Mac isn't counted as work or as Drift.
17. As Dara, I want the menu-bar item to show a square Project dot and the Project's short name in caps, so that I can see Now at a glance.
18. As Dara, I want Now to show the evidence for a confident match (e.g. "Matched by ~/code/todo-agent"), so that I can trust or correct it.
19. As Dara, I want Now to show "No Project" when nothing matches, so that unmatched time is honest rather than guessed.
20. As Dara, I want a Neutral app or site (Terminal outside a repo, chat, search, reference docs) to keep Now on the last matched Project for about 15 minutes, so that looking something up doesn't count as leaving my work.
21. As Dara, I want a short default Neutral list that I can add to, so that cross-cutting tools work out of the box.
22. As Dara, I want, after about 2 minutes on a stable unmatched app and title, one screenshot read by Haiku that guesses the Project or none, so that the assistant can help when Signals aren't enough.
23. As Dara, I want that guess cached per app and title, so that the same window doesn't cost repeated screenshots.
24. As Dara, I want a guess shown with a hollow dashed dot and "?", and "· guess" in the dropdown, so that I can tell it from a confident match.
25. As Dara, I want a guess to ask "Is this <Project>? [Yes] [No, it's…]", so that I can confirm or fix it in one click.
26. As Dara, I want a Haiku guess never to be saved as a Matcher without my click, so that nothing is learned silently.
27. As Dara, I want raw screenshots never stored and discarded after the API call, so that screen contents don't build up on disk.

### Projects and Matchers

28. As Dara, I want to declare a Project myself with one or more Matchers (repo path, Sheet id, URL prefix, calendar keyword), so that the work I care about is recognised.
29. As Dara, I want a repo-path Matcher to also cover the VS Code workspace (via the window title) and the Terminal's working directory, so that one Matcher covers all my code tools.
30. As Dara, I want URL-prefix Matchers to refuse bare domains like `github.com`, so that a Matcher can't swallow unrelated work.
31. As Dara, I want the most specific Matcher (longest path or URL prefix) to win when several fit, so that "Learning .NET" (`learn.microsoft.com/*/training/`) beats Neutral reference docs on the same site.
32. As Dara, I want conflicts settled in a fixed order (foreground over calendar, then most specific, then the Committed Task's Project, then most recently matched), so that Now is predictable.
33. As Dara, I want a tie alone never to trigger a screenshot, so that cost stays low.
34. As Dara, I want the assistant to propose a new Project only when the same unmatched Signal comes up on 2+ separate days, showing "Seen on 2 days: <key>", so that proposals are rare and grounded.
35. As Dara, I want to accept a proposed Project in one click, creating it with that Matcher, or dismiss it, so that nothing is created silently.
36. As Dara, I want "Not this ▸ [Projects / Neutral / None]" on Now, so that I can fix a wrong match straight away.
37. As Dara, I want a correction to then offer "Always match <key> to X?" or "Always treat <key> as Neutral?" with Always or Just this once, so that I can teach a Matcher in one click.
38. As Dara, I want "Treat <app/site> as Neutral" in the menu, shown only when the window isn't already Neutral, so that I can mark cross-cutting tools quickly.
39. As Dara, I want email sender or thread Matchers to only assign a Suggestion's Project and never set Now, so that reading mail doesn't move my focus.
40. As Dara, I want Projects to be flat, with no sub-projects, so that matching stays simple.
41. As Dara, I want to archive a Project so that it stops matching while its Tasks keep the Project for history.
42. As Dara, I want the assistant to suggest archiving a Project after 30 days with no matched Signals, so that stale Projects don't pile up.
43. As Dara, I want "Learning .NET" set up as an ordinary Project (exercise folders plus the MS Learn training URL prefix), so that study time is tracked like any other work.

### Tasks

44. As Dara, I want each Task to have a title, Source and back-link, status, created date, optional deadline, optional Project, effort (S/M/L) and kind (deep/shallow), so that Next has what it needs to choose well.
45. As Dara, I want effort and kind guessed by the assistant and easy to correct, so that I don't have to fill them in.
46. As Dara, I want Task statuses `open`, `committed` (at most one), `done`, `dropped` and `snoozed` (with a wake date), so that each Task's state is clear.
47. As Dara, I want "waiting on someone" to be a snooze with a note and no wake time, so that blocked work leaves Next until I bring it back.
48. As Dara, I want only me to mark a Task done, with the assistant at most offering "done?" on strong evidence, so that nothing is closed behind my back.
49. As Dara, I want Tasks I add by hand and Tasks from code work to become Tasks straight away, so that my own intentions don't need extra confirming.
50. As Dara, I want a soft delete that moves a Task to a Deleted list, undoable and purged after 30 days, so that mistakes can be reversed.
51. As Dara, I want Mark done available from Now, so that finishing work takes one click.

### Quick-add and interruptions

52. As Dara, I want a ⌥Space quick-add palette, so that I can capture a Task without leaving what I'm doing.
53. As Dara, I want ↩ to add the Task to Now's Project and ⌘↩ to add and start it (making it the Committed Task and setting the old one to resume), so that capture and switching are both one keystroke.
54. As Dara, I want a confirmation panel with Start now and Undo after quick-add, so that a mistaken add is easy to reverse.
55. As Dara, I want, after 10 minutes on no Project while committed to something, the menu to offer "New task: <window title>?" with Add or It's a quick one, so that ad-hoc work is captured without nagging.
56. As Dara, I want Add on an interruption to create and commit that Task and remember the interrupted one, so that I can return to it.
57. As Dara, I want Next to become "Back to what you were doing before the interruption" once the interruption is handled, so that I get back to the plan.

### Next

58. As Dara, I want there always to be exactly one Next, so that I never face an empty "what now?".
59. As Dara, I want Next chosen by hard filters (fits the next free calendar block, deadlines first) and then a score (deadline urgency > continues the current Project > deep work in the morning and shallow in the afternoon > age), so that it reflects how I actually work.
60. As Dara, I want Sonnet to break ties between top candidates and give a one-line reason, so that Next is explained.
61. As Dara, I want the best Task flagged "won't fit before HH:MM" when nothing fits the calendar gap, so that I know the trade-off.
62. As Dara, I want Next to be "Review Suggestions (n)" or "Plan tomorrow" when no Tasks are open, so that Next is never blank.
63. As Dara, I want the Next title in amber with its reason and Start, Skip and Snooze ▸ (1 hour / Till tomorrow / Waiting on someone), so that I can act on it in one click.
64. As Dara, I want Start (accepting Next) to make it the Committed Task, so that Drift is measured against what I chose.
65. As Dara, I want Skip to take a Task out of Next for 2 hours, so that I can defer without snoozing.
66. As Dara, I want the 3rd skip of the same Task to prompt "Snooze till tomorrow / Drop it / Keep it", so that Tasks I keep avoiding get a decision.
67. As Dara, I want Suggestions never to feed Next until accepted, so that unvetted items don't steer my day.

### Drift and the Nudge

68. As Dara, I want Drift detected when Now has confidently matched a different Project, or none, for 5 minutes while I have a Committed Task, so that I'm told when I've wandered.
69. As Dara, I want only confident Projects (a Matcher, a held Neutral or a correction) to count towards Drift, and Haiku guesses never, so that a wrong guess can't nudge me while I'm on task.
70. As Dara, I want Excluded and idle time not to count as Drift, so that private or away time is never flagged.
71. As Dara, I want the Nudge to be a floating panel above the Dock at bottom right, showing "<where you are> ≠ <committed Project>", the window and the Committed Task, so that it's noticeable but not intrusive.
72. As Dara, I want the Nudge to offer Back to it, Switch task, It's related (a Not this correction to the committed Project) and Quiet 30m, so that I can respond in whichever way fits.
73. As Dara, I want the Nudge to fire once per Drift episode and re-arm only after I'm back on the Committed Project, so that it never nags while I'm still away.
74. As Dara, I want the menu bar to show an amber ▲ during Drift without taking over the title, so that the state is visible but calm.

### Menu bar dropdown and prompts

75. As Dara, I want a native-style dropdown ordered as prompts, Now, Next, Add task… (⌥Space), Suggestions ▸, Worth knowing ▸, so that the most actionable things come first.
76. As Dara, I want prompts (Always match?, proposed Project, Is this X?, New task?, skipped 3×, pending Ask confirms) collected in the menu and shown by an amber ● on the menu-bar item, never popping up on their own, so that the assistant doesn't interrupt me.
77. As Dara, I want the surface styled to my reference theme (palette `#0D0F10` / `#303B35` / `#6B706D` / `#A8ADAA` / `#E8ECE9`, accent `#FFA500`, Tektur and JetBrains Mono, chamfered panels, thin HUD rules), so that it looks like mine.

### Suggestions from Sources

78. As Dara, I want Action emails, Sheet rows and notes to become Suggestions that I accept or dismiss in one click, so that imports never clutter my Task list without consent.
79. As Dara, I want an unanswered Suggestion to expire quietly after 7 days, so that the list cleans itself.
80. As Dara, I want Suggestions deduped by a per-Source key (thread id, sheet+row, note id), so that one item never shows up twice.
81. As Dara, I want an edit in the Source to update the Suggestion or the Task's back-link but never a title I set, so that my wording sticks.
82. As Dara, I want no merging across Sources in v1, so that behaviour stays predictable.
83. As Dara, I want registered Sheets polled read-only and changed rows offered as Suggestions, so that work I track in Sheets reaches my Task list.
84. As Dara, I want Apple Notes read via AppleScript, unattended while I'm logged in, with Excluded folders skipped, so that actions in my notes are found.
85. As Dara, I want an accepted Suggestion to keep its back-link to the email, row or note, so that I can jump to the source.

### Email Triage and Digest

86. As Dara, I want only Inbox mail triaged (read or unread, not mail I sent), with a first run covering 3 days back, so that the scope is clear and start-up is cheap.
87. As Dara, I want bulk mail (Gmail Promotions, Social or Forums, a `List-Unsubscribe` header, no-reply senders) dropped by rules before any API call, so that cost and noise stay low.
88. As Dara, I want VIPs (my list plus anyone I emailed in the last 90 days) to bypass the bulk rules but still be triaged, so that people who matter are never lost to a filter.
89. As Dara, I want Haiku to sort each remaining email as Action, Worth knowing or Noise, with a one-line reason and an optional guessed deadline, so that every email has one clear outcome.
90. As Dara, I want only the sender, subject and the first ~2 KB of plain-text body sent to the API (no attachments, nothing from Excluded senders), so that as little as possible leaves my Mac.
91. As Dara, I want raw email bodies never stored, only the Suggestion summary and the Gmail back-link, so that my mail isn't copied locally.
92. As Dara, I want one Suggestion per thread, with a guessed deadline pre-filled and tagged "(guessed)" that becomes the Task's deadline only when I accept, so that guesses never become commitments silently.
93. As Dara, I want Worth-knowing emails shown as at most ~5 Digest lines, newest first, that clear when I read the thread in Gmail or after 24h, so that I stay informed without a backlog.
94. As Dara, I want to turn a Digest line into a Suggestion in one click, so that I can fix a Triage that was too lenient.
95. As Dara, I want a macOS notification only for an Action email from a VIP with a deadline today or tomorrow, so that I'm interrupted only for what's truly urgent.
96. As Dara, I want my Gmail reply to quietly dismiss an un-accepted Suggestion, and a reply on an accepted Task's thread to offer "done?", so that my email behaviour keeps the list current.
97. As Dara, I want a new message on a thread to update its Suggestion's summary and deadline, or mark an open Task's back-link "new reply", so that threads stay one item.
98. As Dara, I want a fresh Action on the thread of a done or dropped Task to become a new Suggestion, so that new asks aren't hidden by old closures.
99. As Dara, I want dismissing a Suggestion to offer "Never from this sender", which sends that sender to Noise, so that I can teach Triage explicitly, with no silent learning.

### Guardrails, exclusions and logs

100. As Dara, I want every Operation, whether from the helper, Claude Code or my clicks, to go through one Guardrail check in the helper, so that no path can skip it.
101. As Dara, I want Task create, edit and complete, accepting or dismissing Suggestions, Commit, snooze, skip, soft delete, Project and Matcher changes I asked for, and adding an Exclusion to run as Auto, so that everyday upkeep is instant.
102. As Dara, I want bulk edits of more than 5 Tasks (with a preview), Projects and Matchers the assistant proposes, and removing an Exclusion to be Ask, so that sweeping or privacy-loosening changes need my confirm.
103. As Dara, I want an Ask to return "pending" to its caller and be confirmed only in the menu bar, so that Claude Code's allow-list can never turn it into Auto.
104. As Dara, I want several Asks from one request shown as one confirm, so that a single request doesn't mean many clicks.
105. As Dara, I want a pending Ask to expire after 30 minutes, or when the conversation that started it ends, and to be logged as "expired, not run", so that stale requests never run late.
106. As Dara, I want to make any Operation stricter, and loosen Ask → Auto only for a narrow scope (one Operation type, optionally one Project or Sheet), with each change logged, so that I control autonomy without opening broad holes.
107. As Dara, I want Never Operations (money, credentials, system or security settings, permanent deletion, acting in Excluded apps) not to be possible at all, so that no configuration can enable them.
108. As Dara, I want an "Exclude this app or site" item in the menu bar, so that I can protect something the moment I notice it.
109. As Dara, I want private-browsing windows, secure text fields and system password prompts always Excluded, with no way to change that, so that the most sensitive moments are safe by default.
110. As Dara, I want nothing read or sent for an Excluded app or site (no title, URL, screenshot or body), only "Excluded" and the time recorded, and that time counted as Neutral, so that exclusion is complete but Now stays coherent.
111. As Dara, I want an Operation log (tier, who started it, whether it was confirmed, undo data) kept 90 days and viewable from the menu bar, so that I can audit and undo what happened.
112. As Dara, I want an API audit log with metadata only (time, purpose, model, tokens, cost, kind of content), kept 30 days, so that I can see what was sent and what it cost without it holding content.
113. As Dara, I want Now history kept as Project-level time blocks (Project, Committed Task, start, end) with no titles or URLs, for 90 days, so that a record exists for later features without exposing detail.
114. As Dara, I want the helper never to run shell commands, so that code work stays under Claude Code's own permissions.

### Claude Code conversation

115. As Dara, I want Claude Code to connect to the helper's local MCP server (Streamable HTTP on 127.0.0.1, token-protected), so that conversation can read and change my Tasks.
116. As Dara, I want to ask Claude Code to "plan my day" using my Tasks, calendar, Suggestions and Digest from MCP tools, so that I get a conversational plan over the same data the menu bar uses.
117. As Dara, I want to review and bulk-edit Tasks from Claude Code, with edits of more than 5 Tasks coming back as a pending Ask I confirm in the menu bar, so that conversation is powerful but still guarded.
118. As Dara, I want to ask Claude Code about my Projects and Matchers, and have it propose new ones as Asks, so that I can reorganise conversationally.
119. As Dara, I want Claude Code never to touch the database file directly, so that the helper stays the single writer and keeps its rules (dedupe, a single Committed Task, Suggestion expiry).
120. As Dara, I want everything I can do to Tasks from conversation to exist as a helper MCP tool, so that the MCP contract is the complete interface.

### Cost and reliability

121. As Dara, I want awareness on Haiku 5.5 at about $0.05/day and the whole helper plus conversations at about $0.35/day, visible through the audit log, so that cost is predictable.
122. As Dara, I want the helper to keep sensing and serving Now and Next from rules when the API or network is unavailable, falling back without the AI tie-break or guesses, so that it degrades gracefully.
123. As Dara, I want background polling to resume cleanly after sleep, restart or a token refresh, so that imports don't silently stop.

## Implementation Decisions

**Shape (ADR 0001).** A native Swift helper (macOS 14+, built locally, login item, not notarized) plus Claude Code as conversation only. The helper calls the Messages API directly: Haiku 5.5 for awareness, screenshot guesses and Triage, Sonnet 5.5 for the Next tie-break. API key only, no Pro/Max plan. Secrets are kept in the Keychain.

**Modules.** The helper is split into a deep, UI-free core and thin adapters around it:

- **AssistantCore** (a Swift package with no UI and no OS calls). This is the whole domain:
  - *Now resolver*: Signals → Matcher evaluation → Project → likeliest Task. It covers Neutral hold (~15 min), conflict order (foreground > calendar > most specific > Committed Project > most recent), the 2-minute unmatched → one screenshot guess (cached per app+title), and confident vs guess status.
  - *Drift and interruption tracker*: the 5-minute confident off-Project threshold, once per episode with re-arm on return, the 10-minute "New task?" prompt, and remembering the interrupted Task.
  - *Next selector*: hard filters (calendar gap, deadlines), the score, a tie-break port, the fallbacks ("won't fit before HH:MM", "Review Suggestions (n)", "Plan tomorrow", "Back to what you were doing…"), Skip demotion for 2h, and the 3rd-skip prompt.
  - *Task store*: Tasks, Projects, Matchers, Suggestions, Digest lines, VIPs and Exclusions, with these invariants: at most one Committed Task, per-Source dedupe keys, no overwrite of a user-set title, 7-day Suggestion expiry, 30-day soft-delete purge, and archived Projects matching nothing.
  - *Intake*: maps Source items (email thread, sheet row, note) to Suggestions or Task back-link updates, including the thread-update rules and "reply → dismiss / done?".
  - *Triage*: the bulk-mail rules, the VIP bypass, a classifier port returning a tier, a reason and an optional deadline, Digest management (≤5 lines, clears on read or after 24h), and the notification rule (VIP Action due today or tomorrow).
  - *Guardrail*: tiers every Operation, runs Auto, returns pending for Ask, groups Asks from one request, handles expiry (30 min or end of conversation) and narrow loosening, and has no Never path at all. Every state change goes through it.
  - *Prompts*: the ordered collection of pending prompts and Ask confirms that the menu bar shows.
  - *Logs*: the Operation log (90d), the API audit log (metadata only, 30d) and Now history (Project time blocks, 90d).
- **Ports** (protocols in the core, with real adapters in the helper and fakes in tests): Clock; Signal source (active app, window title via Accessibility, EventKit calendar, idle via CGEventSource, browser URL via Apple Events, git via FSEvents on `.git/HEAD` and the reflog); Screenshot capturer (ScreenCaptureKit window capture, never persisted); Model client (Haiku awareness/guess, Haiku Triage, Sonnet tie-break, each recording an audit entry); Gmail source (`gmail.readonly`, `history.list` polling); Sheets source (`spreadsheets.readonly`, registered sheets only); Notes source (Apple Notes via AppleScript/JXA); Notifier; Persistence (SQLite in Application Support, written only by the helper).
- **Exclusion filter**: applied inside the core where Signals enter, before any port can send data out. Always-Excluded classes (private browsing, secure fields, system password prompts) are hard-coded. An Excluded Signal becomes an "Excluded + time" Signal that the resolver treats as Neutral.
- **MCP adapter**: a local MCP server (Swift MCP SDK, Streamable HTTP on `127.0.0.1`, bearer token stored in the Keychain and handed to Claude Code's config at setup). Each tool maps one-to-one onto a core Operation or query and declares its tier. Tools that change state return either a result or `pending` with an Ask id. Pending Asks are tied to the MCP session, so they expire when it closes.
- **Menu-bar UI adapter**: AppKit/SwiftUI rendering of the core's state (menu-bar title, dropdown, quick-add palette, Nudge panel, Ask confirms) in the reference theme. It holds no domain logic and calls the core's Operations as "Dara".
- **OAuth adapter**: a desktop loopback + PKCE flow for the helper's own Google client (In Production, personal-use unverified), with token refresh.

**Core interface (shape, not code).** The core is driven by inputs and read through state snapshots:

- Inputs: a Signal arrives, the clock advances, a Source item arrives (email thread or message, sheet row, note), or an Operation is requested `(operation, startedBy: helper | claudeCode | dara, requestId?)` → `ran(result) | pending(askId) | refused(never)`, plus confirm or decline of an Ask.
- Queries: Now (Project, Task, confidence: matched / neutral-held / corrected / guess / none / excluded, evidence), Next (Task or fallback, reason, flags), prompts, Suggestions, Digest, the Drift state and any pending Nudge, Task and Project lists, the Operation log, Now history and audit totals.

**MCP tool contract (v1).** Read tools: Now, Next, Tasks (filterable), Projects and Matchers, Suggestions, Digest, today's calendar blocks, Operation log, Now history. Operation tools: create, edit, complete, snooze, drop and soft-delete Task; commit Task; skip Next; accept or dismiss Suggestion; bulk-edit Tasks (Ask when more than 5, with a preview); create, edit and archive Project and Matcher (Auto when Dara asked for it explicitly in conversation, Ask when the assistant proposes it); add an Exclusion (Auto) and remove one (Ask). No tool exists for Never Operations or for anything in the Acting layer.

**Task status model.** `open | committed | done | dropped | snoozed(wake?, note?)`, with at most one `committed`. Only an Operation started by Dara can set `done` from conversation or the menu. The assistant may only raise a "done?" prompt.

**Polling.** Gmail via `history.list` with a first run 3 days back. Registered Sheets and Apple Notes are polled on a modest interval, and every poller resumes from a stored cursor after sleep or restart.

**Privacy.** Only summaries go to the API: email sender, subject and the first ~2 KB of plain text, and screenshots for guesses that are never stored. Raw email bodies and screenshots are never persisted. Now history has no titles or URLs.

**Notes app.** Apple Notes is assumed. The map still marks this "to confirm"; Google Keep has no consumer API and is not supported.

## Testing Decisions

**What makes a good test.** Tests exercise external behaviour through the seam: feed inputs, then check the observable state and the effects at the ports. They do not reach into internal types, private scoring weights or table layouts. A test should read like a user story, for example: "given Committed Task in Project A, when Signals match Project B for 5 minutes on the clock, then one Nudge is pending; a further 10 minutes produces no second Nudge". Time is always driven by the fake Clock, never by real sleeps.

**Seam 1: AssistantCore (behaviour).** Nearly all tests go here. The core is built with fakes for every port: Clock, Signal source, Screenshot capturer, Model client (scripted responses, records what was sent), Gmail, Sheets and Notes sources, Notifier, and in-memory Persistence. Areas covered:

- Now resolution: Matcher specificity, the conflict order, Neutral hold and expiry, archived Projects, Excluded → Neutral, the 2-min guess with caching, guesses not counting as confident, and corrections with Always / Just this once.
- Drift and interruptions: the threshold, once-per-episode, re-arm, idle and Excluded not counting, guesses not counting, the 10-min "New task?", and resuming after an interruption.
- Next: filters, score ordering, the tie-break port invoked only on ties, every fallback, Skip for 2h, the 3rd-skip prompt, and Suggestions never feeding Next.
- Task store invariants: a single Committed Task, dedupe keys, title preservation, Suggestion expiry, soft-delete purge.
- Intake and Triage: the bulk rules, VIP bypass, Excluded senders never reaching the Model client fake, the ~2 KB body limit, tier outcomes, guessed deadlines applied only on accept, Digest cap and clearing, the notification rule, all thread-update rules, and "Never from this sender".
- Guardrails: each v1 Operation's tier, pending/confirm/decline, grouping, 30-min and end-of-conversation expiry, narrow loosening, Never refused, and every outcome written to the Operation log.
- Privacy: assert on what reached the Model client and Persistence fakes. No raw bodies or screenshots are persisted, and no titles or URLs appear in Now history or the audit log.

**Seam 2: MCP contract.** One contract suite drives the real MCP adapter in-process over a real core with fake ports. For each tool it checks the input and output schema, the declared tier and the pending/confirm/expire behaviour (including expiry when the MCP session closes). It also checks that a request without the token is rejected, that the server binds only to 127.0.0.1, and that no tool exists for a Never Operation. This suite is what keeps ADR 0001's "the MCP tool set is the contract" and ADR 0002's "Claude Code's allow-list can't skip an Ask" true.

**Not unit-tested.** The real OS sensor, ScreenCaptureKit, OAuth, Gmail, Sheets and AppleScript adapters, and the AppKit UI. These stay thin. A manual smoke checklist (permissions granted, the menu bar renders in the theme, quick-add, Nudge placement, an Ask confirm round trip from Claude Code) covers them. Optional live-adapter checks can be run by hand against Dara's own account.

**Prior art.** None yet: the repo has no code. The clickable prototype on branch `prototype/now-next-surface` (`prototypes/now-next-surface/index.html`, commit `378a21d`) is the reference for UI behaviour and copy, and its interactions map directly onto core scenarios.

## Out of Scope

- **Acting layer**: opening apps, repos and files, filing notes, editing Sheets, drafting or sending email, calendar writes, and any screen control, including the choice between a Pro/Max plan for Claude Code computer use and the API computer-use tool in the helper. Tiers for these are already recorded in ADR 0002, but no tools ship in v1. Gmail and Sheets stay read-only (`gmail.compose` is not requested).
- **Voice**: push-to-talk, wake word, speech-to-text.
- **Learning support beyond an ordinary Project**: study plans, progress tracking, "next lesson" as a Next.
- **Daily rhythm features**: a structured morning plan and end-of-day review flow, beyond whatever Claude Code can already do conversationally over the v1 MCP tools.
- **History features**: timesheets, weekly summaries or reviews built on Now history. v1 only records it.
- **Silent learning** of Matchers, Triage preferences or Next weights.
- **Cross-Source merging** of duplicate items.
- **Google Keep** and Google Docs as notes Sources.
- **Background or scheduled work in Claude Code.**
- **Multiple users or accounts, other platforms (Windows, mobile), notarization, distribution or sale.**

## Further Notes

- Thresholds (Drift 5 min, interruption 10 min, Neutral hold ~15 min, guess after ~2 min, Skip 2h, Suggestion 7d, Digest 24h, Ask 30 min) are decisions from the map and prototype. Keep them as named constants in the core so they can be tuned without changing behaviour elsewhere.
- Research findings that informed this spec are on branches `research/macos-activity-signals`, `research/gmail-sheets-notes-access` and `research/build-options`.
- Glossary discipline: avoid "important email", "todo", "current task", "audit log" (for the Operation log) and "action" (for an Operation), per `CONTEXT.md`.
- Open confirmation carried over from the map: Dara to confirm Apple Notes is the notes app in use.

## Comments

### 2026-10-17 — dara

**Resolution.** v1 is built. All 19 slices merged to `main` (GitHub #2–#20, PRs #21–#39), from the walking skeleton through first-run setup and log retention. The suite passes (421 tests). Items under *Out of Scope* stay out and can be picked up as new specs.
