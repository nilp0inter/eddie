# Type erasure via closures and WidgetFns bundle

**The decision.** Widget type erasure uses an opaque `WidgetHandle` type with closures that close over a `WidgetFns` record, rather than passing 10 individual function parameters to every internal function.

## Why this and not the alternatives

The original plan called for a `Widget(model, msg)` typed record plus a separate `WidgetHandle` opaque type built by `from_widget`. During implementation, three alternatives were considered:

1. **Direct 10-parameter threading** — every internal function (`build_handle`, `execute_cmd_loop`, `do_dispatch_llm`, etc.) takes all 10 typed functions as individual parameters. This compiled but produced unreadable code, and every new widget feature would require updating every function signature.

2. **Single `WidgetConfig` as the bundle** — reuse the public `WidgetConfig` type internally. This leaks internal structure into the public API and conflates "configuration for creating a widget" with "runtime function table."

3. **`WidgetFns` internal record** (chosen) — a private record type that bundles the function table. `WidgetConfig` is the public creation API; `WidgetFns` is the internal runtime representation. `build_handle` takes just `fns` and `model`.

The `WidgetConfig` was also separated from a hypothetical `Widget` type. The plan's `Widget(model, msg)` type was dropped entirely — `WidgetConfig` serves the same purpose as the creation input, and `WidgetFns` serves as the internal representation.

## What it costs

- One extra type (`WidgetFns`) that mirrors `WidgetConfig` fields. The duplication is small and contained within `widget.gleam`.
- The `create` function copies fields from `WidgetConfig` to `WidgetFns`, which is pure boilerplate.

## What would make us reconsider

If Gleam gains first-class module signatures or existential types, the closure-based approach could be replaced with a more direct abstraction. Until then, this is the idiomatic Gleam pattern for heterogeneous collections.
