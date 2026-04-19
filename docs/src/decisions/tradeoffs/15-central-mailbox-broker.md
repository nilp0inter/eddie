# Central mailbox broker for agent communication

**The decision.** Agent-to-agent communication goes through a single shared `MailboxBroker` OTP actor rather than agents sending messages directly to each other's Subjects.

## Why this and not the alternatives

The main alternative was direct actor-to-actor messaging — each agent would hold its parent's and children's Subjects and send messages directly. This was rejected because:

- Direct messaging requires each agent to know the other agent's `Subject(AgentMessage)`, creating tight coupling. The broker decouples agents — they only need to know agent IDs (strings).
- Messages need persistence — if a child agent finishes a turn and sends results to its parent, but the parent is mid-turn and not listening, the message must be stored. The broker provides inbox persistence by design.
- The broker is the single source of truth for mailbox state, making it trivial to serve the full inbox/outbox to the frontend via `MailboxUpdated` events.
- Read/unread tracking is centralised — no need for each agent to implement its own bookkeeping.

A secondary alternative was event-based communication via the agent tree (agents publish events, tree routes them). This was rejected because it conflates the tree's role (lifecycle management) with communication concerns.

## What it costs

- Single point of failure — if the broker crashes, all inter-agent communication stops. No supervision or persistence to disk.
- Single-threaded bottleneck — all mail flows through one actor's mailbox. With many agents sending frequently, the broker could become a throughput constraint.
- Extra hop — every message crosses two actor boundaries (sender → broker → recipient notification) instead of one (sender → recipient).
- In-memory only — all messages are lost on restart. No history survives a BEAM restart.

## What would make us reconsider

- Agent count grows large enough (hundreds) that the broker's single-threaded throughput becomes measurable. Sharding by agent ID or using ETS would be the likely fix.
- We need durable message delivery (guaranteed delivery across restarts). This would require a persistent store (database, disk queue) and likely a different architecture.
- Communication patterns become more complex (pub/sub, topics, fan-out) — at that point the broker would need to evolve into a proper message bus or be replaced by an existing one.
