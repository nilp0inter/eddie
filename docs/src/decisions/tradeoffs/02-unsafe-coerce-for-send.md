# Unsafe coercion for WidgetHandle.send

**The decision.** `WidgetHandle.send` uses an Erlang FFI identity function (`eddie_ffi.erl`) to coerce a `Dynamic` value back to the concrete `msg` type, bypassing Gleam's type system.

## Why this and not the alternatives

The `send` function allows parent code (like Context) to forward typed messages to child widgets. The problem: `WidgetHandle` erases the `msg` type parameter, so the caller passes `Dynamic` and the handle must recover the original type internally.

Alternatives considered:

1. **Decode via `gleam/dynamic/decode`** — requires the widget to register a decoder for its msg type. This is heavyweight: every widget would need a JSON-like decoder for an internal Gleam type that never crosses a serialization boundary.

2. **Typed send via phantom types** — would require Context to track the concrete msg type per widget, defeating the purpose of type erasure.

3. **Erlang identity function** (chosen) — on the BEAM, all values are dynamically typed at runtime. The Erlang `identity(X) -> X` function is a no-op that satisfies Gleam's type checker. Safety is guaranteed by the call site: only code that created the widget (and knows the concrete type) calls `send`.

## What it costs

- One Erlang FFI file (`eddie_ffi.erl`) with a single trivial function.
- A safety invariant that the type checker cannot enforce: the caller must pass the correct type. Misuse would cause a runtime crash, not a compile error.

## What would make us reconsider

If Gleam adds `unsafe_coerce` as a language primitive or if the number of FFI shims grows beyond 2-3, we should consolidate the approach. If `send` proves to be a source of runtime crashes, we should switch to the decode-based approach despite the boilerplate.
