# The helper enforces Guardrails; Claude Code's permissions are not relied on

Every Operation, whether the helper starts it, Claude Code calls it through an MCP tool, or Dara clicks it, passes through the helper's Guardrail check. An Ask Operation returns "pending" to its caller and is confirmed only in the helper's menu bar. It expires after 30 minutes, or when the conversation that started it ends. We chose this because Claude Code's permission prompts can be allow-listed away per tool, after which a "send email" or "edit Sheet" tool would run unconfirmed. The helper already owns all state (ADR 0001), so owning the rule that guards it keeps that rule in one place and impossible to skip.

## Considered Options

- **Rely on Claude Code's permission prompts for chat-started Operations**: rejected. One "always allow" silently turns every Ask into Auto.
- **Both layers**: rejected as the design; Claude Code's prompts may still appear, but nothing depends on them.
- **Let the helper run shell commands under an allow-list**: rejected. Code work stays in Claude Code under its own permissions, and the helper runs no commands at all.

## Consequences

- Every MCP tool that changes state carries a tier, and Ask tools need a pending/confirm/expire flow plus a menu-bar confirm UI.
- Dara may make Operations stricter, or loosen Ask → Auto for a narrowly scoped case. Never tiers are fixed. Every tier change and every Operation is written to the Operation log.
- Screen control, when it arrives, runs inside this check: each run is Ask with a stated goal, and each step is still tiered.
