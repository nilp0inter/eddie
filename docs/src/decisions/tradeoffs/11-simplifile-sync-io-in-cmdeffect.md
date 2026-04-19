# Synchronous simplifile IO inside CmdEffect

**The decision.** The file explorer widget performs filesystem operations (directory listing, file reading) synchronously inside `CmdEffect` closures using the `simplifile` library. When dispatched by the LLM, the effect runs in a spawned process (via the agent's `EffectPending` pattern). When dispatched by UI events, the effect runs inline via `widget.resolve`.

## Why this and not the alternatives

Two alternatives were considered:

1. **Erlang FFI for file operations** — avoids adding a dependency but requires maintaining FFI wrappers for `file:list_dir`, `file:read_file`, and `filelib:is_dir`. `simplifile` wraps these already with proper error types and is a well-maintained Gleam library.

2. **Explicitly async file operations with custom message passing** — the widget could spawn its own processes and manage results. This was rejected because `CmdEffect` already provides the perform/resume abstraction. Since Phase 3, `CmdEffect` yields `EffectPending` at the widget boundary, and the agent spawns the effect in a separate process automatically. The widget doesn't need to manage concurrency itself.

## What it costs

- **New dependency** — `simplifile` is added to the project's dependencies. It is well-maintained and widely used in the Gleam ecosystem, but it is one more thing to update.
- **UI dispatch blocks the actor** — when file operations are triggered via `dispatch_ui` (browser events), effects are resolved synchronously via `widget.resolve`. A slow filesystem (network mount, large directory) would block the agent actor for the duration of the read. LLM-triggered effects don't have this problem since they run in spawned processes.
- **No streaming** — large files are read entirely into memory as a single string. There is no chunked reading or size limit.

## What would make us reconsider

- File operations need to run against remote filesystems or very large directories where blocking becomes noticeable.
- UI-triggered file operations become too slow and need to be async (would require making `dispatch_ui` return an async result, which is a larger change to the widget protocol).
- `simplifile` is abandoned or the Gleam ecosystem standardises on a different file library.
