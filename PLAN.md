# Rose-Tree Agents with Mailbox Communication

## Context

Eddie currently has a shallow agent tree: one mandatory root agent + a flat `Dict` of children (depth 1). The frontend shows agents as tabs within the conversation view. The user wants to transform this into:

- A **list of independent rose-trees** (arbitrary depth nesting)
- **No initial agent** — start with an empty list
- A **landing page** showing the agent list, separate from the conversation view
- **Instant root creation** via "+" button (UUID id, default label, default prompt)
- **Subagents spawned by parent agents** via tools (goal + initial message, run in background)
- **Mailbox widget** for free-form parent-child communication
- A **control WebSocket** (`/ws/control`) for real-time tree updates on the list page

---

## Phase 1: Shared types

Add new types to `shared/` with JSON codecs.

### `shared/src/eddie_shared/agent_info.gleam` (new file)

Move `AgentInfo` here from `protocol.gleam` and extend:

```gleam
pub type AgentStatus { AgentIdle  AgentRunning  AgentCompleted  AgentError }

pub type AgentInfo {
  AgentInfo(id: String, label: String, parent_id: Option(String), status: AgentStatus)
}

pub type AgentTreeNode {
  AgentTreeNode(info: AgentInfo, children: List(AgentTreeNode))
}
```

### `shared/src/eddie_shared/mailbox.gleam` (new file)

```gleam
pub type MailMessage {
  MailMessage(id: String, from: String, to: String, content: String, timestamp: Int, read: Bool)
}
```

### `shared/src/eddie_shared/protocol.gleam`

- Update `AgentInfo` import to new module
- Replace `AgentListChanged` with `AgentTreeChanged(roots: List(AgentTreeNode))`
- Add: `MailReceived(message: MailMessage)`, `MailSent(message: MailMessage)`, `MailboxUpdated(inbox: List(MailMessage), outbox: List(MailMessage))`
- Add: `ChildAgentStatusChanged(agent_id: String, status: AgentStatus)`
- Replace `SpawnAgent` command with `SpawnRootAgent` (no id/label — server generates UUID + default label)
- Add: `SubagentsUpdated(children: List(AgentInfo))` server event
- Add JSON codecs for all new types

### Tests

- Roundtrip codec tests for `AgentInfo`, `AgentTreeNode`, `MailMessage`, new `ServerEvent`/`ClientCommand` variants

---

## Phase 2: Backend — agent_tree rewrite

### `backend/src/eddie/agent_tree.gleam` (rewrite)

Replace `TreeState` with a forest of `AgentEntry` records:

```gleam
type AgentEntry {
  AgentEntry(
    subject: Subject(AgentMessage),
    label: String,
    parent_id: Option(String),
    child_ids: List(String),
    status: AgentStatus,
  )
}

type TreeState {
  TreeState(
    agents: Dict(String, AgentEntry),
    base_config: AgentConfig,
    send_fn: ...,
    subscribers: List(Subject(String)),  // control WS subscribers for tree changes
  )
}
```

New messages:
- `SpawnRootAgent(id, reply_to)` — creates a top-level agent with defaults
- `SpawnChildAgent(id, label, parent_id, goal, initial_message, override, reply_to)` — creates child, sends initial message, updates parent's child_ids
- `GetAgentTree(reply_to)` — returns `List(AgentTreeNode)` (rose-tree forest)
- `GetChildren(parent_id, reply_to)` — returns child `List(AgentInfo)`
- `GetParent(child_id, reply_to)` — returns `Option(String)`
- `UpdateStatus(agent_id, status)` — called when agent starts/finishes turns
- `SubscribeTree(subscriber)` / `UnsubscribeTree(subscriber)` — for control WS
- Keep `GetAgent(id, reply_to)` (flat lookup)
- Remove `GetRoot`, `ListAgents` (replaced by `GetAgentTree`)

On `SpawnChildAgent`:
1. Create child agent actor with merged config
2. Insert into agents Dict with `parent_id: Some(parent_id)`
3. Update parent's `child_ids`
4. Send initial user message to child via `agent.send_message`
5. Broadcast `AgentTreeChanged` to tree subscribers

Public API functions mirror the messages. Add a helper `build_tree(agents: Dict) -> List(AgentTreeNode)` that assembles the rose-tree from the flat Dict.

### `backend/src/eddie.gleam`

- Remove root agent creation — start tree empty
- Pass `base_config` (with placeholder agent_id) to `agent_tree.start`
- Start mailbox broker (Phase 4), pass to tree
- `agent_tree.start` no longer spawns any agent

### `backend/src/eddie/agent.gleam`

- Add `ChildSpawned(child_id: String, child_label: String)` to `AgentMessage`
- Extend `AgentConfig` with `parent_id: Option(String)` and `mailbox_broker: Option(Subject(MailboxMessage))`
- In `build_context`: conditionally add mailbox and subagent_manager widgets based on config
- Add `GetStatus(reply_to: Subject(AgentStatus))` message — derives status from `llm_in_flight`/`pending_effects`
- On `TurnStarted`/`TurnCompleted`, notify tree via `UpdateStatus`

### Tests

- `start_empty_tree_test` — list returns empty
- `spawn_root_agent_test` — spawns, appears in tree
- `spawn_child_agent_test` — spawns under root, tree has depth 2
- `spawn_grandchild_test` — depth 3 works
- `get_children_test`, `get_parent_test`

---

## Phase 3: Backend — mailbox broker + widgets

### `backend/src/eddie/mailbox_broker.gleam` (new file)

Central OTP actor for message routing:

```gleam
type BrokerState {
  BrokerState(
    mailboxes: Dict(String, List(MailMessage)),    // agent_id -> inbox
    outboxes: Dict(String, List(MailMessage)),     // agent_id -> sent
    subscribers: Dict(String, List(Subject(MailMessage))),
    next_id: Int,
  )
}
```

Messages: `SendMail`, `ReadMail`, `ReadUnread`, `MarkRead`, `GetOutbox`, `Subscribe`, `Unsubscribe`

On `SendMail`: create `MailMessage`, append to recipient's inbox + sender's outbox, notify recipient's subscribers.

Started once in `eddie.gleam`, Subject passed through agent_tree to each agent.

### `backend/src/eddie/widgets/mailbox.gleam` (new file)

Follows existing widget pattern (like `goal.gleam`).

Model: `agent_id`, `parent_id`, `child_ids`, cached `inbox`/`outbox`, broker Subject.

LLM tools (dynamic based on parent/children):
- `send_to_parent(message)` — if has parent
- `send_to_child(child_id, message)` — if has children
- `read_mailbox()` — read all inbox messages
- `check_unread()` — read unread only

All use `CmdEffect` to call broker actor. `view_messages` shows mailbox summary. `view_state` returns `MailboxUpdated`. Frontend tools: same set for UI interaction.

### `backend/src/eddie/widgets/subagent_manager.gleam` (new file)

Gives parent agents the `spawn_subagent` tool.

Model: `agent_id`, `tree: Subject(AgentTreeMessage)`, `children: List(SubagentInfo)`

LLM tools:
- `spawn_subagent(label, goal, initial_message)` — generates UUID, calls `agent_tree.spawn_child` via `CmdEffect`
- `list_subagents()` — shows children and status (queries tree via `CmdEffect`)
- `check_subagent(child_id)` — single child status

`view_messages` shows subagent summary to LLM. `view_state` returns `SubagentsUpdated`.

### Tests

- Mailbox broker: send/receive, unread tracking, subscriber notification
- Mailbox widget: tool dispatch, CmdEffect flow
- Subagent manager: spawn tool dispatch

---

## Phase 4: Server updates

### `backend/src/eddie/server.gleam`

**New route**: `/ws/control` — control WebSocket
- Subscribes to agent_tree's tree subscribers
- Handles `SpawnRootAgent` command (generates UUID server-side, calls `agent_tree.spawn_root`)
- Sends initial `AgentTreeChanged` on connect
- Receives tree change broadcasts

**Updated routes**:
- Remove `/ws` (bare, no agent_id) backward-compat route
- `/ws/<agent_id>` unchanged (404 if agent not found)
- `GET /agents` → returns tree structure (`List(AgentTreeNode)` as JSON)

**SpawnRootAgent handling**:
1. Generate UUID (Erlang `uuid` or simple unique ID via erlang FFI)
2. Call `agent_tree.spawn_root(tree, id)`
3. Tree broadcasts `AgentTreeChanged` to all control WS clients

**Remove** old `handle_spawn_agent` (was for the tab-based SpawnAgent command).

### UUID generation

Add an Erlang FFI function for UUID v4 generation in `eddie_ffi.erl`:
```erlang
generate_uuid() -> list_to_binary(uuid:to_string(uuid:uuid4())).
```
Or use a simpler approach with `erlang:unique_integer` + timestamp if UUID dep is unwanted.

---

## Phase 5: Frontend rewrite

### `frontend/src/eddie_frontend.gleam`

**Navigation model**:
```gleam
type Page {
  AgentListPage
  AgentConversationPage(agent_id: String)
}
```

**Model changes**:
- Add `page: Page` (init to `AgentListPage`)
- Add `control_ws: Option(WebSocket)` — always-on control channel
- Replace `agent_list: List(AgentInfo)` with `agent_tree: List(AgentTreeNode)`
- Remove `active_agent`, `show_spawn_form`, `spawn_form`
- Keep `agents: Dict(String, AgentState)` for caching

**New Msg variants**:
- `NavigateToAgent(agent_id: String)` — switch to conversation page
- `NavigateToList` — back to list page
- `CreateRootAgent` — "+" button clicked
- `ControlWsEvent(WebSocketEvent)` — control channel events
- `MailboxEvent(...)` — for mailbox panel updates

**Add to AgentState**: `subagents: List(AgentInfo)`, `inbox: List(MailMessage)`, `outbox: List(MailMessage)`

**New sidebar panels**: `SubagentsPanel`, `MailboxPanel`

**Init**:
1. Connect control WebSocket to `/ws/control`
2. No agent WebSocket yet (list page)
3. Receive initial `AgentTreeChanged` with empty tree

**AgentListPage view**:
- Header: "Eddie"
- "+" button → sends `SpawnRootAgent` via control WS
- List of root agent cards showing: label, status indicator, child count
- Click card → `NavigateToAgent(id)`

**NavigateToAgent flow**:
1. Set `page: AgentConversationPage(agent_id)`
2. Open agent WebSocket to `/ws/<agent_id>`
3. Keep control WS open (still gets tree updates)

**NavigateToList flow**:
1. Close agent WebSocket
2. Set `page: AgentListPage`

**ConversationPage view**:
- Back button / breadcrumb → `NavigateToList`
- Current chat UI (log, input, sidebar)
- New sidebar panels: Subagents (tree of children + status), Mailbox (inbox/outbox)

**apply_server_event additions**:
- `AgentTreeChanged` → update `model.agent_tree`
- `SubagentsUpdated` → update `agent_state.subagents`
- `MailboxUpdated` → update `agent_state.inbox`, `agent_state.outbox`
- `MailReceived` → append to inbox
- `MailSent` → append to outbox

### `frontend/src/eddie_frontend_ffi.mjs`

Add `generateUuid()` — use `crypto.randomUUID()`. (Actually, UUID is generated server-side per the instant-create decision, so this may not be needed.)

---

## Phase 6: Integration + cleanup

- Remove old `SpawnAgent` command and `AgentListChanged` event from protocol
- Remove old spawn form UI code
- Update `serve_index` HTML if needed (title, initial styles)
- End-to-end test: start server, create root via "+", chat, spawn subagent via tool, check mailbox

---

## Verification

1. `task test:unit` — all shared codec roundtrip tests pass, all backend widget/actor tests pass
2. `task backend:lint` — glinter clean
3. `task format` — formatted
4. `task build:local` — all three packages compile
5. `task frontend:bundle` — JS bundle builds
6. Manual: start server, verify empty list page, click "+", see new agent, click into conversation, have LLM spawn a subagent, verify mailbox communication works, navigate back to list, see tree structure

---

## Critical files

| File | Change |
|------|--------|
| `shared/src/eddie_shared/agent_info.gleam` | New — `AgentInfo`, `AgentStatus`, `AgentTreeNode` |
| `shared/src/eddie_shared/mailbox.gleam` | New — `MailMessage` type + codecs |
| `shared/src/eddie_shared/protocol.gleam` | New events/commands, remove old ones |
| `backend/src/eddie/agent_tree.gleam` | Rewrite — forest of `AgentEntry`, new messages |
| `backend/src/eddie/agent.gleam` | Extend config, add `ChildSpawned`, conditional widgets |
| `backend/src/eddie/mailbox_broker.gleam` | New — central mail routing actor |
| `backend/src/eddie/widgets/mailbox.gleam` | New — mailbox widget |
| `backend/src/eddie/widgets/subagent_manager.gleam` | New — spawn_subagent tool widget |
| `backend/src/eddie/server.gleam` | Add `/ws/control`, remove `/ws`, update spawn handling |
| `backend/src/eddie.gleam` | Start empty, create broker, pass to tree |
| `backend/src/eddie_ffi.erl` | Add UUID generation FFI |
| `frontend/src/eddie_frontend.gleam` | Page navigation, list view, mailbox/subagent panels |

## Reusable existing code

| What | Where |
|------|-------|
| Widget pattern (WidgetConfig, WidgetHandle, type erasure) | `backend/src/eddie/widget.gleam` |
| CmdEffect async pattern | `backend/src/eddie/cmd.gleam` |
| Context compositor (add widget, tool dispatch) | `backend/src/eddie/context.gleam` |
| Goal widget as template for simple widgets | `backend/src/eddie/widgets/goal.gleam` |
| File explorer as template for CmdEffect widgets | `backend/src/eddie/widgets/file_explorer.gleam` |
| WebSocket upgrade + registry broadcast | `backend/src/eddie/server.gleam` |
| `agent.merge_config` for child config inheritance | `backend/src/eddie/agent.gleam:53` |
| `process.call` pattern for actor communication | Throughout backend |
