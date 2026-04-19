# Closure-based widget injection to break import cycles

**The decision.** `AgentTree` constructs `SubagentManager` and `Mailbox` widget handles and injects them into `AgentConfig.extra_widgets` at spawn time, using closures (`SpawnFn`, `ListChildrenFn`) instead of passing `Subject(AgentTreeMessage)` directly to the widget modules. This breaks what would otherwise be a three-module import cycle: `agent_tree` → `agent` → `subagent_manager` → `agent_tree`.

## Why this and not the alternatives

Gleam does not support import cycles. Three alternatives were considered:

1. **Move spawn logic out of subagent_manager** — the widget would only produce a `CmdToolResult` describing the spawn request, and the agent or server would handle the actual spawning. This breaks the widget's self-containment and spreads spawn logic across modules.
2. **Merge agent_tree and subagent_manager** — eliminates the cycle but creates a monolithic module mixing tree management with widget UI/tool concerns.
3. **Extract a shared interface module** — define a `TreeApi` type with spawn/list functions, imported by both agent_tree and subagent_manager. This adds a module that exists purely for cycle-breaking with no conceptual value.

The closure approach keeps the widget self-contained (it owns its tools, update, and views) while the tree provides the concrete implementations at construction time. The closures capture the tree Subject in their closure environment, so the widget never imports `agent_tree`.

## What it costs

- The `SpawnFn` signature (`fn(String, String, String, String, String) -> Result(Nil, String)`) is a positional 5-argument function with no named parameters — easy to misorder. Adding or removing a parameter requires updating both the closure construction in `agent_tree.build_extra_widgets` and the call site in `subagent_manager.update`.
- Error types are flattened to `String` at the closure boundary — the widget cannot pattern-match on specific `SpawnError` variants. Error messages are baked into the closure.
- The widget cannot be tested in isolation without providing mock closures.

## What would make us reconsider

- Gleam adds support for import cycles (unlikely — it's a deliberate language design choice).
- The number of cross-tree operations grows beyond spawn and list (e.g., kill agent, transfer agent, reparent) — at that point, extracting a proper `TreeApi` interface module becomes worthwhile despite the indirection.
- The positional argument list grows beyond 5-6 parameters — a record type for the spawn request would be clearer.
