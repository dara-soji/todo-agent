---
id: 6
title: "What makes an email important?"
labels: [wayfinder:grilling]
status: closed
assignee:
parent: 1
blocked_by: []
---

## Question
When the assistant scans Dara's email, what counts as **important**: who it's from, keywords, deadlines, being asked to do something? What happens to an important email: it becomes a Task, Dara gets notified, or a summary is shown? What about everything else?

## Comments

### 2026-10-10 — dara (grilling session)

**Resolution.** Glossary terms added to `CONTEXT.md`: Triage, Action email, Worth knowing, Noise, Digest, VIP. "Important" is now on the avoid list.

- **Scope of Triage:** Inbox only, read or unread, excluding mail Dara sent. First run looks back 3 days.
- **Tiers:** every email is triaged into exactly one: **Action** (asks Dara to do, reply to or decide something, or has a deadline) → Suggestion; **Worth knowing** → Digest line; **Noise** → dropped silently.
- **Judging:** rules first drop bulk mail (Gmail Promotions/Social/Forums, `List-Unsubscribe` header, no-reply senders unless VIP). Haiku then triages the rest, returning a tier, a one-line reason and an optional guessed deadline.
- **What goes to the API:** sender, subject and the first ~2 KB of plain-text body; no attachments. Senders on the privacy exclude list are never sent. Raw bodies aren't stored, only the Suggestion summary plus the Gmail back-link.
- **VIP:** a list Dara edits, plus anyone Dara emailed in the last 90 days. VIPs bypass the bulk-mail rules but are still triaged.
- **Suggestions:** one per thread. A guessed deadline is shown pre-filled and tagged "(guessed)", and becomes the Task's deadline only on accept. Suggestions never feed Next.
- **Digest:** a "Worth knowing" section in the menu-bar dropdown under Now/Next, at most ~5 lines, newest first. A line clears when the thread is read in Gmail or after 24h. One click promotes a line to a Suggestion.
- **Notifications:** a macOS notification only for an Action email from a VIP with a deadline today or tomorrow. Everything else is a quiet Suggestion count plus the Digest.
- **Gmail-side handling:** if Dara replies, an un-accepted Suggestion is dismissed quietly. Archiving changes nothing. Replying on a thread whose Task is accepted makes the assistant offer "done?".
- **Thread updates:** a new message updates the existing Suggestion's summary and deadline, or marks an open Task's back-link "new reply". A fresh Action on a done or dropped Task's thread becomes a new Suggestion.
- **Learning:** explicit only. Dismissing a Suggestion offers "Never from this sender", which mutes that sender to Noise, and Digest lines can be promoted. No silent learning in v1.
- **Deferred:** matching email to a Project → *How are Projects defined and matched to Signals?*. The Digest's role in a morning plan → Daily rhythm (not yet specified).
