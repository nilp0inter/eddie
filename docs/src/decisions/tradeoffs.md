# Trade-off Summary

1. [Type erasure via closures and WidgetFns bundle](./tradeoffs/01-type-erasure-via-closures.md) — how WidgetHandle hides concrete model/msg types
2. [Unsafe coercion for WidgetHandle.send](./tradeoffs/02-unsafe-coerce-for-send.md) — Erlang FFI identity function to recover erased types
3. [Result types instead of panics](./tradeoffs/03-result-over-panic.md) — tool.new and widget.send return Result instead of asserting
4. [Typed ConversationLog bypassing WidgetHandle](./tradeoffs/04-typed-conversation-log-in-context.md) — Context holds conversation log as typed opaque type for protocol access
5. [Inline HTML + plain JS over Lustre SPA](./tradeoffs/05-inline-html-over-lustre-spa.md) — ~~self-contained HTML page served from server.gleam~~ **superseded** (Phase 2 removed HTML from backend, replaced with domain events)
6. [Synchronous turn loop inside the agent actor](./tradeoffs/06-synchronous-turn-in-actor.md) — LLM turn loop blocks the actor mailbox for simplicity over responsiveness
7. [Dual-strategy structured output](./tradeoffs/07-dual-strategy-structured-output.md) — tool-call and native strategies exposed as caller's choice rather than auto-detected or hardcoded
8. [Dynamic-to-JSON re-encoding via Erlang FFI](./tradeoffs/08-dynamic-to-json-ffi-roundtrip.md) — string round-trip to transform opaque json.Json values
9. [Agent tree without OTP supervision](./tradeoffs/09-agent-tree-without-supervision.md) — standalone child actors without supervisor restart or health monitoring
10. [Token usage recording via Context reconstruction](./tradeoffs/10-token-usage-via-context-rebuild.md) — string ID lookup and Context rebuild to deliver usage data to the token_usage widget
11. [Synchronous simplifile IO inside CmdEffect](./tradeoffs/11-simplifile-sync-io-in-cmdeffect.md) — file explorer blocks the agent actor during filesystem operations
12. [Client-side markdown rendering](./tradeoffs/12-client-side-markdown-rendering.md) — ~~regex-based JS parser in the browser~~ **superseded** (Phase 2 removed inline frontend; revisit in Phase 4 Lustre SPA)
