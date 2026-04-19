# Typed ConversationLog bypassing WidgetHandle in Context

**The decision.** The Context compositor holds the conversation log as a typed `ConversationLog` opaque type (with direct access to the model) rather than as a type-erased `WidgetHandle` like all other widgets.

## Why this and not the alternatives

Context needs two things from the conversation log that the `WidgetHandle` abstraction cannot provide:

1. **Protocol checking** — before dispatching any tool call, Context must call `check_protocol` on the conversation log's model to enforce task rules. This function takes a `ConversationLogModel` directly.
2. **Owning task ID** — when recording responses and tool results, Context must tag log items with the active task's ID via `current_owning_task_id`.

Both operations require typed access to the model, which is hidden behind `WidgetHandle`'s closure-based type erasure.

Three alternatives were considered:

1. **Store the model separately alongside the WidgetHandle** — Context holds both `WidgetHandle` and a shadow `ConversationLogModel`, kept in sync. This doubles the state and creates a dangerous consistency invariant: every mutation to the handle must also update the shadow model, but the handle's internal model is unreachable after dispatch.

2. **Add protocol-checking hooks to WidgetHandle** — extend the opaque type with an optional `check_protocol` closure slot. This generalises a one-off need into the core abstraction, adding complexity for all widgets to serve one.

3. **Typed `ConversationLog` wrapper** (chosen) — the conversation_log module exposes a `ConversationLog` opaque type that wraps the model and provides typed dispatch/send functions alongside the type-erased `WidgetHandle` factory. Context uses this typed API for dispatch and protocol checks, and can produce a `WidgetHandle` on demand (via `to_handle`) when it needs the type-erased interface for `view_html`.

## What it costs

- The conversation_log module has a **duplicated Cmd loop** (`execute_log_cmd_loop`) that mirrors `widget.execute_cmd_loop`. Changes to Cmd semantics must be updated in both places.
- The conversation log is treated **asymmetrically** — it's the only widget that Context interacts with through a typed API rather than through `WidgetHandle`. This is a leak in the widget abstraction: anyone reading Context must understand why one widget is special.
- `ConversationLog` and `WidgetHandle` can drift: if someone creates a `WidgetHandle` via `create()` and a `ConversationLog` via `init()`, they are independent — there is no shared state.

## What would make us reconsider

- If a second widget needs typed access from Context (e.g. a goal widget needing protocol-level coordination), the asymmetry doubles and a generic solution becomes worthwhile — likely extracting the "protocol participant" concept into a trait-like pattern.
- If Gleam gains existential types or first-class module signatures, the typed model could be recovered from `WidgetHandle` without the coercion workaround, eliminating the need for the parallel API.
- If the Cmd loop semantics change (new Cmd variants, async execution), the duplicated loop becomes a maintenance hazard. At that point, extracting the loop into a shared function that both `widget.gleam` and `conversation_log.gleam` call would be the fix.
