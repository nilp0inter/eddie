# Trade-off Summary

1. [Type erasure via closures and WidgetFns bundle](./tradeoffs/01-type-erasure-via-closures.md) — how WidgetHandle hides concrete model/msg types
2. [Unsafe coercion for WidgetHandle.send](./tradeoffs/02-unsafe-coerce-for-send.md) — Erlang FFI identity function to recover erased types
3. [Result types instead of panics](./tradeoffs/03-result-over-panic.md) — tool.new and widget.send return Result instead of asserting
