# Trade-off Summary

1. [Type erasure via closures and WidgetFns bundle](./tradeoffs/01-type-erasure-via-closures.md) — how WidgetHandle hides concrete model/msg types
2. [Unsafe coercion for WidgetHandle.send](./tradeoffs/02-unsafe-coerce-for-send.md) — Erlang FFI identity function to recover erased types
3. [Result types instead of panics](./tradeoffs/03-result-over-panic.md) — tool.new and widget.send return Result instead of asserting
4. [Typed ConversationLog bypassing WidgetHandle](./tradeoffs/04-typed-conversation-log-in-context.md) — Context holds conversation log as typed opaque type for protocol access
5. [Inline HTML + plain JS over Lustre SPA](./tradeoffs/05-inline-html-over-lustre-spa.md) — self-contained HTML page served from server.gleam instead of compiled Gleam-to-JS frontend
6. [Synchronous turn loop inside the agent actor](./tradeoffs/06-synchronous-turn-in-actor.md) — LLM turn loop blocks the actor mailbox for simplicity over responsiveness
