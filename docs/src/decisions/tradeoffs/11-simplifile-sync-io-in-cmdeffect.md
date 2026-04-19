# Synchronous simplifile IO inside CmdEffect

**The decision.** The file explorer widget performs filesystem operations (directory listing, file reading) synchronously inside `CmdEffect` closures using the `simplifile` library, running on the agent actor's process.

## Why this and not the alternatives

Two alternatives were considered:

1. **Erlang FFI for file operations** — avoids adding a dependency but requires maintaining FFI wrappers for `file:list_dir`, `file:read_file`, and `filelib:is_dir`. `simplifile` wraps these already with proper error types and is a well-maintained Gleam library.

2. **Spawning a separate process for IO** — the `CmdEffect` perform function could spawn a process and return a `Subject` for the result, keeping the agent actor unblocked during IO. This was rejected because `CmdEffect` is designed to run synchronously within the widget's Cmd loop (the BEAM makes this safe — processes are lightweight and IO is non-blocking at the OS level). The agent actor is already blocked during the turn loop (see [trade-off 06](./06-synchronous-turn-in-actor.md)), so blocking it slightly longer for a local file read adds no new architectural constraint.

## What it costs

- **New dependency** — `simplifile` is added to the project's dependencies. It is well-maintained and widely used in the Gleam ecosystem, but it is one more thing to update.
- **Agent blocked during IO** — a slow filesystem (network mount, large directory) would block the agent actor for the duration of the read. This is the same trade-off as the synchronous turn loop but applied to local IO rather than HTTP.
- **No streaming** — large files are read entirely into memory as a single string. There is no chunked reading or size limit.

## What would make us reconsider

- File operations need to run against remote filesystems or very large directories where blocking becomes noticeable.
- A second widget needs IO effects that are genuinely slow (network calls, database queries) — at that point, `CmdEffect` should probably spawn a process and the Cmd loop should become async.
- `simplifile` is abandoned or the Gleam ecosystem standardises on a different file library.
