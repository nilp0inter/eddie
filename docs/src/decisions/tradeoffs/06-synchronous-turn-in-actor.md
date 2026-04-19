# Synchronous turn loop inside the agent actor

> **Superseded in Phase 3.** The agent is now a reactive actor that spawns LLM calls and tool effects as async processes. See [trade-off 13: Async agent with spawned effects](./13-async-agent-with-spawned-effects.md).

**The decision.** The agent's LLM turn loop (multiple HTTP round-trips, tool dispatch, state mutations) ran synchronously within the actor's `handle_message` callback, blocking the actor mailbox for the duration of the turn.

## Why this and not the alternatives

Two approaches were considered:

1. **Synchronous in-actor turn (chosen at the time)** — the `RunTurn` handler called `do_run_turn` which looped through LLM calls and tool dispatches, mutating the actor state in place. The actor processed no other messages until the turn completed. Subscriber notifications were sent synchronously between steps.

2. **Offloaded turn in a spawned child process** — the actor would spawn a child process to run the turn, passing it the current Context and `send_fn`. The child would send state diffs (or full Context snapshots) back to the actor via messages. The actor would remain responsive to `GetState`, `Subscribe`, and `DispatchEvent` during the turn.

The synchronous approach was chosen because:
- It was dramatically simpler. The turn loop mutated `AgentState` directly and had access to the subscriber list for notifications. No inter-process serialisation of Context (which contains closures in WidgetHandle — not trivially serialisable).
- OTP actors are designed for exactly this pattern: own your state, process messages one at a time. The BEAM scheduler preempts long-running processes, so the turn didn't starve other actors.
- For single-user Milestone 1, there was exactly one turn in flight at a time. Mailbox blocking had no practical impact because `Subscribe` happened at WebSocket init (before any turn) and `GetState` was unused in the hot path.

## What it cost

- **All other agent messages were queued during a turn.** A `GetState` call blocked until the turn finished. A `Subscribe` sent mid-turn meant the new subscriber missed updates from that turn. A `DispatchEvent` (browser widget interaction) was delayed.
- **No mid-turn cancellation.** The only way to stop a turn was the 25-iteration cap or HTTP timeouts. There was no mechanism for the server to tell the agent "stop this turn."
- **Multi-agent contention.** With `AgentTree`, each child agent is its own actor (not sharing a process), so inter-agent contention was avoided. However, within a single agent, rapid user messages serialised, and any cross-agent communication (parent querying child state during a turn) would block.

## Why it was superseded

Phase 3 replaced the synchronous turn loop with a reactive actor that spawns LLM calls and tool effects as async processes. The agent never blocks — it processes `UserMessage`, `LlmResponse`, `ToolEffectResult`, and other messages as they arrive. User messages that arrive during an in-flight turn are queued and processed after the current turn completes. This resolved the mailbox blocking problem and opened the path to mid-turn widget interaction and turn cancellation.
