# Agent tree without OTP supervision

**The decision.** `AgentTree` spawns all agents (roots and children at arbitrary depth) as standalone OTP actors via `agent.start_with_send_fn` instead of placing them under an OTP supervisor. The tree itself is an OTP actor (for runtime spawning, lookup, and tree structure), but it does not supervise its agents.

## Why this and not the alternatives

The main alternative was using `gleam_otp`'s `supervisor` module to supervise child agents, which would provide automatic restart on crash and structured shutdown. This was rejected because:

- The current agent actor has no crash recovery semantics — a crashed turn loop loses all context state (the entire `Context` is in-process memory). Restarting a crashed agent with an empty context is worse than not restarting, since the user loses all conversation history with no indication of what happened.
- Supervision adds complexity (child specs, restart strategies, shutdown ordering) that provides no value until agents have persistent state that can survive a restart.

## What it costs

- No automatic recovery if an agent process crashes — the tree actor will hold a dead Subject, and calls to it will time out. With rose-tree nesting, a crashed parent leaves orphaned children with a dead `parent_id`.
- No structured shutdown — stopping the tree does not stop agents. Orphaned actors continue running until the BEAM VM shuts down.
- No health monitoring — the tree has no way to detect a crashed agent without attempting to communicate with it.
- Mailbox messages sent to a crashed agent accumulate in the broker with no delivery.

## What would make us reconsider

- Agents gain persistent state (database-backed context) that allows meaningful recovery after a crash.
- Multi-user scenarios where an agent crash should not silently break the experience — a supervisor could restart and serve a "session lost" message.
- The tree grows deep enough that orphaned processes become a resource concern.
