# Synchronous turn loop inside the agent actor

**The decision.** The agent's LLM turn loop (multiple HTTP round-trips, tool dispatch, state mutations) runs synchronously within the actor's `handle_message` callback, blocking the actor mailbox for the duration of the turn.

## Why this and not the alternatives

Two approaches were considered:

1. **Synchronous in-actor turn (chosen)** — the `RunTurn` handler calls `do_run_turn` which loops through LLM calls and tool dispatches, mutating the actor state in place. The actor processes no other messages until the turn completes. Subscriber notifications are sent synchronously between steps.

2. **Offloaded turn in a spawned child process** — the actor would spawn a child process to run the turn, passing it the current Context and `send_fn`. The child would send state diffs (or full Context snapshots) back to the actor via messages. The actor would remain responsive to `GetState`, `Subscribe`, and `DispatchEvent` during the turn.

The synchronous approach was chosen because:
- It is dramatically simpler. The turn loop mutates `AgentState` directly and has access to the subscriber list for notifications. No inter-process serialisation of Context (which contains closures in WidgetHandle — not trivially serialisable).
- OTP actors are designed for exactly this pattern: own your state, process messages one at a time. The BEAM scheduler preempts long-running processes, so the turn doesn't starve other actors.
- For single-user Milestone 1, there is exactly one turn in flight at a time. Mailbox blocking has no practical impact because `Subscribe` happens at WebSocket init (before any turn) and `GetState` is unused in the hot path.

## What it costs

- **All other agent messages are queued during a turn.** A `GetState` call blocks until the turn finishes. A `Subscribe` sent mid-turn means the new subscriber misses updates from that turn. A `DispatchEvent` (browser widget interaction) is delayed.
- **No mid-turn cancellation.** The only way to stop a turn is the 25-iteration cap or HTTP timeouts. There is no mechanism for the server to tell the agent "stop this turn."
- **Multi-agent contention.** With Phase 6's `AgentTree`, each child agent is its own actor (not sharing a process), so inter-agent contention is avoided. However, within a single agent, rapid user messages still serialize, and any cross-agent communication (parent querying child state during a turn) would block.

## What would make us reconsider

- **Multi-user access to a single agent** where one user's long turn blocks another user's input. At that point, offloading the turn to a child process (or using a task process from `gleam_otp`) becomes necessary.
- **Real-time widget interaction during turns** (e.g., the user wants to toggle a task expansion while the LLM is running). Currently this is queued; if it needs to be instant, the actor must remain responsive.
- **Turn cancellation is requested.** Implementing cancel requires the actor to be able to interrupt the turn, which is impossible if the turn runs synchronously in the actor process.
