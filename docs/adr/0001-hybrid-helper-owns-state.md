# Hybrid build: a Swift helper owns all state and background work; Claude Code is conversation only

The assistant is a native Swift menu-bar helper plus Claude Code. The helper is always on and owns sensing, Now, Drift, Next, background imports, email Triage and the task store (SQLite, with the helper as its only writer). It calls the Messages API directly: Haiku 5.5 for awareness and Triage, Sonnet 5.5 to break ties when picking Next. Claude Code does no background work. It is the conversational layer ("plan my day", reviewing Tasks, asking about Projects) and reaches the task store only through the helper's local MCP server. We chose this because per-minute awareness inside Claude Code costs about 35–40x more than a direct Haiku call ($2–8/day vs about $0.05/day), cannot see the frontmost app, and leans on scheduling features that are still in preview. Meanwhile, a fully standalone app would spend most of v1 rebuilding the agent loop, memory and connectors that Claude Code already gives us for conversation.

## Considered Options

- **Claude-native** (Claude Code runs the awareness loop, plus a thin menu-bar helper): rejected on cost, freshness and preview-feature risk.
- **Standalone** (one app with its own agent loop, including chat): rejected on effort (about 4–6 weeks vs 2–3).
- **Claude Code doing imports and Triage on a schedule via connectors**: rejected. With API-key billing each run costs about $0.10–0.25, and its freshness would be hourly at best.
- **Claude Code editing the SQLite file directly**: rejected. A single writer avoids edit conflicts and keeps rules (dedupe, a single Committed Task, Suggestion expiry) in one place.

## Consequences

- Billing is API key only, with no Pro/Max plan. Claude Code's computer use requires Pro/Max, so screen control for the later Acting layer must either add a subscription or be built in the helper on the API's computer-use tool. That choice is deferred.
- The helper's MCP tool set is the contract between the two parts. Whatever can be done to Tasks from conversation must exist as a helper tool.
- If everything later moves into one process, the MCP contract can stay while the conversational side moves to the Agent SDK.
