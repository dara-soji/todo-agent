# Build options: Claude-native vs standalone vs hybrid

Research for ticket [0004](../issues/wayfinder-v1-spec/0004-build-options.md), feeding the grilling ticket [0007 Pick the build platform](../issues/wayfinder-v1-spec/0007-build-platform.md). Sources were read on 2026-10-10. Prices are from the live pricing page, not from memory. Terms (**Now**, **Next**, **Signal**, **Drift**, **Nudge**, **Guardrail**) follow `CONTEXT.md`.

## TL;DR

- Claude Code's scheduling (`/loop`, Desktop scheduled tasks, cloud routines) is built for work every few minutes to every few hours. It doesn't suit a per-minute awareness sensor. Each fire sends the whole Claude Code session context, and every Desktop task run opens a new session in the sidebar.
- The awareness loop is cheap if a small local process sends compact text Signals straight to the Messages API on **Claude Haiku 5.5**. That works out to roughly **$0.04–$0.08 per working day**. The same loop on Opus 5.5 costs about 35–40x more.
- Either way you have to build a local Mac helper. Nothing Claude-native can read the frontmost app or window title as a background sensor, or draw a menu-bar item. The real choice is where the *thinking* lives: inside Claude Code (skills, MCP, memory, computer use, all for free) or in your own agent loop.
- **Leaning:** a hybrid. A thin native helper handles sensing, cheap Haiku classification, the menu bar and the task store, and exposes everything as an MCP server. Claude Code handles the heavy, occasional work: planning Next, importing from email, notes and Sheets, and later computer use. The decision belongs to ticket 0007.

---

## What each Claude surface gives you out of the box

| Capability | Claude Code / Agent SDK | Messages API (own loop) |
|---|---|---|
| Agent loop, context management, compaction | Built in | You write it, or use the SDK Tool Runner (Python, TS, Java, Go, Ruby, C#, PHP; **no Swift SDK**) [A1] |
| File, Bash, web tools | Built in [C1] | Server tools for web search, web fetch and code execution. Bash and text editor are schema-less tools you execute yourself [A1] |
| Skills, CLAUDE.md memory, subagents, plugins | Built in, loaded from `.claude/` and `~/.claude/` [C1] | Skills via the API; the memory tool `memory_20250818` runs against a backend you implement [A1] |
| MCP servers (Gmail, Sheets, your own) | Built in; tool definitions deferred by default [C6] | MCP connector, remote URL servers only (`mcp_toolset`) [A1] |
| Hooks | 32 lifecycle events; command, http, mcp_tool, prompt and agent handlers. They fire only on Claude Code's own events (tool calls, prompts, file changes, cwd changes), **not on OS events** such as app switches [C5] | n/a (your code *is* the hook) |
| Scheduling | `/loop` and cron (session-scoped, 1-min minimum, 7-day expiry); Desktop scheduled tasks (1-min minimum, app must be open, Mac awake); cloud routines (1-hour minimum, no local files) [C2][C3] | You schedule it (launchd, a timer in the app) |
| Push events into a running session | Channels (research preview): an MCP server pushes events into an open session [C7] | n/a |
| Computer use on the real Mac | CLI and Desktop: macOS research preview, **Pro/Max plan only**, **interactive only (not `-p`)**, per-app approval, Esc to abort, one session at a time [C4] | `computer_toolset_20260801`: you implement screenshot, click and type on the Mac yourself. Docs recommend a dedicated VM or container. About 4,500 tokens of toolset overhead per request [A2][A3] |
| Billing | Claude Code CLI: subscription (Pro $20/mo, Max from $100/mo) or API key [P2]. **Agent SDK: API key**. The docs say third-party products may not offer claude.ai login [C1] | API key, per token [P1] |

## Option (a): Claude-native

**Shape:** Claude Code as the brain, with skills (`plan-next`, `triage-inbox`, `import-notes`), MCP servers for Gmail, Sheets and Notes (see ticket 0003), CLAUDE.md and auto memory, and scheduled tasks. A small menu-bar helper shows Now/Next and collects Signals, because Claude Code has neither a menu-bar surface nor a background OS sensor.

**What you get for free:** the agent loop, tool permissions with Guardrail-like allow and deny rules, skills, MCP, memory, subagents, Claude Code computer use (interactive), and `/usage` cost tracking [C1][C6].

**Running in the background all day:**
- `/loop 1m …` in a backgrounded session runs only while that session lives. Recurring tasks expire after 7 days. The scheduler adds deterministic jitter: up to 5 min of delay on a 10-minute schedule and up to 30 min on hourly ones [C2].
- Desktop scheduled tasks need the Claude app open and the Mac awake. Missed runs collapse to one catch-up run. **Each run starts a fresh session** that shows up in the sidebar, which is noisy at a per-minute cadence [C3].
- Channels let the helper *push* events into a long-lived session instead of polling. But channels are a research preview, the session must stay open, and unattended runs need permission handling [C7].
- Every fire carries the session's full context. The docs name scheduled tasks as a reason usage climbs in long sessions [C6].

**Cost per day of awareness (estimate):** a 10-hour day. Assumption: a Claude Code turn carries about 30k tokens of context (system prompt, tool names, CLAUDE.md, recent history). This is unverified; check it with `/context`. Output is about 400 tokens including adaptive thinking, which can't be turned off on Opus 5.5, Sonnet 5.5 or Haiku 5.5 [C6].

| Cadence × model | Per fire | Per day |
|---|---|---|
| Every 5 min (120/day), Opus 5.5 (default) | 30k cache read × $0.20/M + 400 out × $20/M ≈ $0.014 | **≈ $1.70** |
| Every 1 min (600/day), Opus 5.5 | ≈ $0.014 | **≈ $8.40** |
| Every 5 min, `--model haiku` | 30k × $0.01/M + 400 × $0.50/M ≈ $0.0005 | **≈ $0.06** |

The table assumes the cache stays warm. On an API key the cache TTL is 5 minutes by default [C6], and scheduler jitter can push a 5-minute cadence past it, causing full-price re-writes (30k × $5/M ≈ $0.15 per miss on Opus 5.5). On a Pro or Max subscription these come out of plan usage limits rather than dollars, and a per-minute loop on the default model would eat a large share of them. Cache misses after idle gaps re-send the full context at the uncached rate [C6].

**Effort to a usable v1:** low on the agent side and medium on the helper side. Roughly 1–2 weeks part-time: about 3–5 days for a Swift `MenuBarExtra` helper with active app, window title and calendar, about 2–4 days for skills and MCP configuration plus the task-file format, and about 2 days to tune the prompts. *(Judgment, not sourced.)*

**Weak spots:** the always-on loop is the part Claude Code is worst at. The helper and Claude Code have to share state, through a file or MCP. Computer use can't run headless. Scheduled-task behaviour is mostly research preview or recently changed.

## Option (b): standalone Mac app on the Messages API

**Shape:** one app (Swift, or Electron/Tauri) that owns the sensors, the menu bar, the task store and its own agent loop. It calls the API directly with custom tools (`get_tasks`, `set_now`, `create_task`, `search_mail`, …) and, later, `computer_toolset_20260801`.

**What you get for free:** only the API: tool use, structured outputs, prompt caching, vision, the computer-use toolset, web search and fetch, and the MCP connector for remote servers [A1]. You write the loop, memory, permissions, Guardrails, the Gmail and Sheets OAuth integrations, retries and cost tracking yourself. Swift has no official SDK, so you'd call it over raw HTTP. Electron can use the TypeScript SDK. Tauri can use TS in the webview, or Rust over raw HTTP [A1].

**Running in the background all day:** natural. It's a login item with a timer, or event-driven on app or window change. You control cadence, model and context size per call, which is what makes the cheap numbers below possible. Window titles need the macOS Accessibility permission. Electron and Tauri need a native module or sidecar for that (see ticket 0002).

**Cost per day of awareness (estimate):** a 10-hour day. The local process gathers the Signals (app, window title, calendar event, current Task) and sends a **small classification prompt**:

- Fixed prefix (instructions plus the task list) of about 2,000 tokens, cached. Haiku 5.5's minimum cacheable prefix is 512 tokens [A4]. Checks every ≤5 min keep the 5-minute cache warm [A4].
- Variable part of about 300 tokens. Output about 150 tokens, with thinking at `low` effort. Thinking can be disabled on Haiku 5.5 at effort `high` or below [A1].
- Prices per MTok [P1]: **Haiku 5.5** $0.10 in, $0.01 cache read, $0.50 out (prompts ≤100k tokens). **Sonnet 5.5** $2, $0.10, $10. **Opus 5.5** $4, $0.20, $20.

| Item | Haiku 5.5 | Sonnet 5.5 | Opus 5.5 |
|---|---|---|---|
| One check (2k cached + 300 in + 150 out) | ≈ $0.00013 | ≈ $0.0023 | ≈ $0.0046 |
| Every 60 s → 600 checks/day | **≈ $0.08** | ≈ $1.40 | ≈ $2.80 |
| Event-driven (~200 app/window changes + 5-min heartbeat ≈ 320/day) | **≈ $0.04** | ≈ $0.74 | ≈ $1.50 |
| "Unsure" screenshots: 1280×800 ≈ 1,334 visual tokens (⌈1280/28⌉×⌈800/28⌉) [A3], 30/day | ≈ $0.005 | ≈ $0.08 | ≈ $0.16 |
| Re-plan Next, ~15/day (8k cached + 1k in + 1.5k out incl. thinking), on Sonnet 5.5 | — | ≈ $0.27 | — |

A plausible v1 mix: awareness on Haiku 5.5, screenshots on Haiku 5.5, Next planning on Sonnet 5.5. That comes to about **$0.30–$0.40 per day, or about $7–9 per month** of API spend. *(Estimate; check it against `usage` in real responses.)* Don't use computer use for awareness: the toolset alone adds about 4,500 input tokens per request [A2]. A plain image block is enough to read a screenshot.

**Effort to a usable v1:** high. Roughly 4–6 weeks part-time in Swift. Electron or Tauri is similar, with less native UI work but extra native bridging for Accessibility and EventKit. You'd be rebuilding by hand what Claude Code already provides: the loop, Gmail and Sheets connectors, skills, memory and permission rules. *(Judgment, not sourced.)*

**Strong spots:** full control of cadence, cost, privacy (the exclude list is applied before anything leaves the Mac, and nothing raw is stored) and UX. No research-preview dependencies. **Weak spots:** most of the build time goes to plumbing, and the acting layer (computer use on the real Mac) has to be built and made safe yourself.

## Option (c): hybrid (helper + Claude Code)

**Shape:**
1. **Native helper (always on):** the sensors (ticket 0002), the menu-bar Now/Next and Nudges, and the local task store. It runs the cheap **Haiku 5.5** awareness check on the Messages API (option (b)'s cost row, about $0.04–0.08/day). It applies the exclude list locally.
2. **The helper exposes an MCP server** with tools such as `get_now`, `list_tasks`, `create_task`, `set_next` and `recent_activity`. Claude Code sessions then read and write the same task store.
3. **Claude Code for the heavy, occasional work:** skills for "plan my day", "re-plan Next", "import from Gmail, Notes and Sheets" and end-of-day review, run as Desktop scheduled tasks (hourly or daily, where the 1-min/1-hour limits don't hurt) or on demand. Gmail and Sheets come through existing MCP connectors. Later, the acting layer uses Claude Code computer use interactively, inside Claude Code's permission prompts, which map onto the Guardrail tiers in ticket 0009.
4. Optionally, channels to push "Drift detected" or "new important email" into an open session once they leave research preview [C7].

**Running in the background all day:** the helper is a login item. Claude Code runs only when there's real work, so its context cost is paid a few times a day rather than 600 times.

**Cost per day:** helper awareness about $0.05 (Haiku 5.5) plus a handful of Claude Code runs. Each scheduled run starts a fresh session, so its first request writes the context to cache (~50k × $2.50/M ≈ $0.13 on Sonnet 5.5) before later turns read it cheaply. Say 6 runs/day at ≈ $0.10–0.25 each on an API key (≈ $0.60–1.50). On Pro/Max they draw on plan usage instead, where the cache TTL is 1 hour [C6]. **≈ $0.65–$1.60/day on an API key, or ~$0.05/day plus plan usage on a subscription** *(estimate)*.

**Effort to a usable v1:** medium. Roughly 2–3 weeks part-time: the helper with sensors, menu bar, task store and Haiku check (about 1.5–2 weeks, including a small MCP server) plus skills and connector setup (about 3–5 days). *(Judgment, not sourced.)*

**Trade-offs:** you have two moving parts and an MCP contract between them. In exchange, each part sits on the surface it suits best. If you later want everything in one process, the helper's agent work can move to the Agent SDK (TypeScript or Python, API key) without changing the MCP contract.

## Side notes for ticket 0007

- **Language for the helper:** Swift (`MenuBarExtra`, NSWorkspace, Accessibility and EventKit are all native, but there's no Anthropic SDK, so raw HTTP), TypeScript/Electron (official SDK, heavier footprint), or **C#/.NET** (official Anthropic C# SDK [A1], and Dara is learning .NET, but the menu-bar and Accessibility story on macOS is weak). Rust/Tauri means raw HTTP plus a native sidecar.
- **Managed Agents** (Anthropic-hosted loop, scheduled deployments) can't see the Mac, and computer use isn't available there [A2]. That rules it out for awareness.
- **Model IDs:** `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5` [A1]. Haiku 5.5's price jumps 5x for prompts over 100k tokens [P1], so keep awareness prompts small.
- **Several capabilities are research preview:** Claude Code computer use, channels, and some scheduling behaviours [C4][C7]. Anything v1 depends on should avoid research-preview features or tolerate their changing.

## Recommendation (for discussion, not a decision)

Go with **hybrid (c)**. Option (a) puts the per-minute sensor on the one surface that's expensive and awkward for it. Option (b) spends most of v1 rebuilding connectors, memory and an agent loop that Claude Code already provides. The hybrid keeps the always-on part tiny and cheap (Haiku 5.5, about $0.05/day) and native, and pays for Claude Code's large context only a few times a day. It also lets the occasional thinking (planning, triage, imports, and later computer use) inherit Claude Code's skills, MCP and permission model. Ticket 0007 should test four things: whether the MCP contract between the helper and Claude Code is the right seam, which language to use for the helper, and whether Dara is fine with Claude Code runs drawing on plan usage rather than an API key.

## Sources

- [P1] Pricing (model prices, caching multipliers, batch, Haiku 5.5 long-context tier, tool and computer-use overhead): https://platform.claude.com/docs/en/about-claude/pricing
- [P2] Claude plans (Pro $20/mo or $17/mo annual; Max from $100/mo; Claude Code included): https://claude.com/pricing
- [A1] Claude API skill reference, bundled with Claude Code (model IDs, SDK languages, thinking and effort per model, Tool Runner, memory tool, MCP connector); cross-checked with [P1]
- [A2] Computer use tool (`computer_toolset_20260801`, developer-provided environment, VM recommendation, ~1,000–1,800 tokens per screenshot, not in Managed Agents): https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
- [A3] Vision (visual tokens = ⌈w/28⌉×⌈h/28⌉, resolution tiers): https://platform.claude.com/docs/en/build-with-claude/vision
- [A4] Prompt caching (512-token minimum on Haiku 5.5, 5-min TTL refreshed on read, write 1.25x and read 0.1x/0.05x): https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- [C1] Agent SDK overview (capabilities, API-key auth note): https://code.claude.com/docs/en/agent-sdk/overview
- [C2] Scheduled tasks, `/loop` and cron (1-min minimum, 7-day expiry, jitter, session-scoped): https://code.claude.com/docs/en/scheduled-tasks
- [C3] Desktop scheduled tasks (app open and Mac awake, fresh session per run, catch-up): https://code.claude.com/docs/en/desktop-scheduled-tasks
- [C4] Computer use in the CLI (macOS research preview, Pro/Max, interactive only, per-app approval): https://code.claude.com/docs/en/computer-use
- [C5] Hooks reference (32 events, handler types): https://code.claude.com/docs/en/hooks
- [C6] Manage costs (background usage, why usage climbs, thinking always on for 5.5 models, MCP deferral): https://code.claude.com/docs/en/costs
- [C7] Channels (research preview, push into an open session): https://code.claude.com/docs/en/channels
- Headless mode (`-p`, `--bare` uses an API key only, `--permission-prompts none`): https://code.claude.com/docs/en/headless
