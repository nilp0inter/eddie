# Async agent with spawned effects

**The decision.** The agent actor never blocks on LLM calls or tool effects. LLM HTTP requests and `CmdEffect` perform functions are executed in spawned processes that send results back to the agent as actor messages (`LlmResponse`, `LlmError`, `ToolEffectResult`, `ToolEffectCrashed`). The agent remains responsive to all messages at all times.

## Why this and not the alternatives

Three approaches were considered:

1. **Synchronous in-actor turn (previous design, superseded)** — the turn loop ran within `handle_message`, blocking the actor. Simple but prevented the agent from processing subscriptions, widget events, or additional user messages during a turn. See [trade-off 06](./06-synchronous-turn-in-actor.md).

2. **Offloaded turn in a child process** — spawn a single process for the entire turn, sending Context snapshots back. Rejected because Context contains closures (in WidgetHandle) that aren't trivially serialisable between processes.

3. **Reactive actor with spawned IO (chosen)** — the agent stays in control of its state. Only the IO operations (HTTP calls, filesystem effects) are spawned out. Results return as typed actor messages. The agent updates its state and decides what to do next based on the current data (pending effects, queued user messages, iteration count).

The reactive approach was chosen because:
- The agent never gives up ownership of its state. No serialisation of closures, no split-brain between actor and child process.
- The actor remains responsive during LLM calls — `Subscribe`, `Unsubscribe`, `DispatchEvent`, and `GetCurrentState` are all processed immediately.
- User messages arriving during a turn are queued with their reply Subject, then drained in order after the turn completes. This makes `run_turn` (blocking convenience API) and `send_message` (fire-and-forget) coexist naturally.
- The `DispatchResult` / `EffectPending` pattern at the widget level cleanly separates "what to do" from "when to do it" — widgets don't need to know whether they're running synchronously or asynchronously.

## What it costs

- **Complexity.** The agent now tracks `llm_in_flight`, `pending_effects`, `collected_tool_parts`, `current_reply_to`, and `pending_user_messages`. The old agent had none of these — it just ran a synchronous loop.
- **No crash recovery for spawned processes.** `process.spawn` (without link) is used. If a spawned LLM call or effect process crashes, the agent never receives a response for that call. The turn will hang indefinitely — the agent remains alive but stuck waiting. This is better than the old design (where a crash would take down the actor), but worse than proper process monitoring.
- **Eager evaluation pitfall with `bool.guard`.** The `use <- bool.guard(when: cond, return: side_effecting_fn())` pattern evaluates the return value eagerly regardless of the condition. This caused a subtle bug during implementation and was replaced with explicit `case` matching.

## What would make us reconsider

- **Crash recovery becomes critical.** Adding `process.monitor` for spawned processes and handling `ProcessDown` messages would make the pattern robust. If spawned processes crash frequently (network instability, filesystem errors), this becomes necessary.
- **Context needs to be shared across processes.** If a future feature requires multiple processes to read or modify the context simultaneously, the reactive-actor-with-spawned-IO model breaks down and a more sophisticated concurrency model (CRDT, event sourcing) would be needed.
- **The complexity budget is exceeded.** If the agent's message handler becomes too complex to reason about (many more message types, deeply nested state transitions), a state machine or process-per-turn model might be clearer despite the serialisation costs.
