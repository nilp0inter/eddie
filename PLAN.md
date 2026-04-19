# Eddie Architecture Refactor Plan

## Context

Eddie's current architecture has two fundamental limitations:

1. **The agent blocks on LLM calls.** The synchronous `do_run_turn` loop in `agent.gleam` ties up the actor while waiting for HTTP responses. User messages arriving during a turn cannot be processed.

2. **The backend owns the presentation layer.** ~~Widgets produce HTML via `view_html`, the server sends HTML fragments over WebSocket, and the frontend is hand-crafted JavaScript embedded in `frontend.gleam`. This couples backend state management to browser rendering.~~ **(Resolved in Phase 2.)** Widgets now produce `List(ServerEvent)` via `view_state`, and the backend broadcasts JSON-encoded domain events over WebSocket. The `lustre` dependency has been removed from the backend. A minimal event-logging JS stub serves as the temporary frontend.

The target architecture:
- **Non-blocking reactive agent actor** — not a state machine, just an actor that reacts to messages. LLM calls and tool effects are spawned as async processes. The agent never blocks.
- **Three Gleam projects** — `backend/` (Erlang), `frontend/` (JavaScript, Lustre SPA), `shared/` (both targets, domain types + codecs).
- **Domain event protocol** — high-level typed messages (`GoalUpdated`, `TaskCreated`, `UserMessage`, etc.) cross the WebSocket boundary instead of HTML fragments.
- **User and LLM as external peers** — both interact with the agent via fire-and-forget messages. The agent broadcasts state changes to all subscribers.

---

## Phase 1: Create the shared package and monorepo layout ✅

**Status: Complete.**

Restructured into three sibling directories. Extracted pure domain types and protocol codecs into `shared/`. Backend compiles and all 164 tests pass.

### What was done

- Moved all source into `backend/`, created `shared/` and `frontend/` stubs.
- Extracted `MessagePart`, `Message`, `TaskStatus`, `Task`, `ToolDefinition`, `Initiator`, `TurnResult` into `shared/src/eddie_shared/`.
- Defined `ServerEvent`, `ClientCommand`, and snapshot types in `shared/src/eddie_shared/protocol.gleam`.
- Backend imports shared types; keeps glopenai conversion functions locally.
- Updated `Taskfile.yml` for monorepo (component:target pattern).
- Updated `CLAUDE.md` with new project structure.

---

## Phase 2: Replace `view_html` with `view_state` on the backend ✅

**Status: Complete.**

Widgets produce `List(ServerEvent)` instead of HTML. The agent broadcasts JSON-encoded domain events. The `lustre` dependency has been removed from the backend.

### What was done

**Shared package — JSON encoders added:**
- `message.gleam`: `message_part_to_json`, `message_to_json`
- `task.gleam`: `status_to_json`
- `turn_result.gleam`: `to_json`
- `protocol.gleam`: `server_event_to_json`, `server_events_to_json_string`, and encoders for all snapshot types (`TaskSnapshot`, `LogItemSnapshot`, `DirectorySnapshot`, `FileSnapshot`, `TokenRecord`)

**Widget infrastructure:**
- `widget.gleam`: `view_html: fn(model) -> Element(Nil)` → `view_state: fn(model) -> List(ServerEvent)` across `WidgetConfig`, `WidgetFns`, `WidgetHandle`
- `context.gleam`: `current_html`/`changed_html` → `current_state`/`changed_state` returning `List(ServerEvent)`. `HtmlEntry` → `StateEntry` using structural equality for change detection.
- `agent.gleam`: `GetCurrentHtml` → `GetCurrentState`. `notify_subscribers` sends JSON-encoded `ServerEvent` lists. Tool call/result notifications use `ToolCallStarted`/`ToolCallCompleted` protocol events.
- `server.gleam`: WebSocket sends JSON domain events. Turn start/complete use protocol events.

**Widget view_state implementations:**
- `system_prompt`: `[SystemPromptUpdated(text: model.text)]`
- `goal`: `[GoalUpdated(text: model.text)]`
- `token_usage`: `[TokensUsed(input, output)]` per record (chronological order)
- `file_explorer`: `[FileExplorerUpdated(directories: [...], files: [...])]`
- `conversation_log`: `TaskCreated` per task + `ConversationAppended` per log item

**Frontend:** Replaced with a minimal event-logging stub that displays raw JSON events in the browser console.

**Removed:** `lustre` dependency from `backend/gleam.toml`, all `lustre/*` imports from backend source and tests.

---

## Phase 3: Non-blocking reactive agent

**Goal:** Replace the synchronous `do_run_turn` loop with a reactive actor that never blocks. No state machine — the agent simply reacts to each incoming message based on its current data.

### Design principle

The agent is a plain OTP actor. It holds domain state and reacts to messages. Its behavior emerges from the data (is there an LLM call in flight? are there pending effects? are there queued user messages?) rather than from an explicit phase enum.

### Agent state

```gleam
pub type AgentState {
  AgentState(
    context: Context,
    config: LlmConfig,
    subscribers: List(Subject(List(ServerEvent))),
    send_fn: fn(Request(String)) -> Response(String),
    // Async bookkeeping — just data, not "phases"
    llm_in_flight: Bool,
    pending_user_messages: List(String),
    pending_effects: Dict(String, EffectContinuation),
    iteration: Int,
  )
}
```

`pending_effects` tracks in-flight `CmdEffect` processes. Each is keyed by the tool call ID it belongs to. `EffectContinuation` holds the `resume` closure (see below).

### Agent messages

```gleam
pub type AgentMessage {
  // From external sources (users, other actors)
  UserMessage(text: String)
  UserCommand(command: ClientCommand)
  Subscribe(subscriber: Subject(List(ServerEvent)))
  Unsubscribe(subscriber: Subject(List(ServerEvent)))

  // From spawned LLM process
  LlmResponse(response: Response(String))
  LlmError(reason: String)

  // From spawned effect process
  ToolEffectResult(call_id: String, data: Dynamic)
  ToolEffectCrashed(call_id: String, reason: String)
}
```

### Message handling (reactive, not state-machine)

Each message handler checks the current state and acts accordingly:

**`UserMessage(text)`:**
- Add message to context, broadcast `ConversationAppended`
- If `!llm_in_flight` and no pending effects: compose LLM request, spawn HTTP process, set `llm_in_flight = True`, broadcast `TurnStarted`
- If busy: append to `pending_user_messages`

**`UserCommand(command)`:**
- Dispatch to the appropriate widget as a UI event (always lightweight, no IO)
- Broadcast resulting `ServerEvent`s
- No queuing needed — these are instant state mutations

**`LlmResponse(response)`:**
- Set `llm_in_flight = False`
- Parse response, record in context, broadcast events
- If text-only response: broadcast `TurnCompleted(Success)`, then drain queued user messages (if any, pick the next one and start a new turn)
- If tool calls: dispatch each tool call through context. For each:
  - If result is `Completed(handle, result)`: record result, broadcast `ToolCallStarted`/`ToolCallCompleted`
  - If result is `EffectPending(perform, resume)`: spawn a process to run `perform`, store the `resume` continuation in `pending_effects`, broadcast `ToolCallStarted`
  - After all non-effect calls are processed: if no pending effects, compose next LLM request and spawn it. If pending effects exist, wait for them to complete.

**`LlmError(reason)`:**
- Set `llm_in_flight = False`
- Broadcast `TurnCompleted(Error(reason))`
- Drain queued user messages

**`ToolEffectResult(call_id, data)`:**
- Look up `resume` in `pending_effects`, remove it
- Call `resume(data)` → may return `Completed` or another `EffectPending`
- If `EffectPending`: spawn again, store new `resume`
- If `Completed`: record tool result, broadcast `ToolCallCompleted`
- If no more pending effects: compose next LLM request, spawn it

**`ToolEffectCrashed(call_id, reason)`:**
- Remove from `pending_effects`
- Record error as tool result, broadcast `ToolCallCompleted` with error
- If no more pending effects: compose next LLM request, spawn it

### The EffectPending/Completed pattern in widget dispatch

`dispatch_llm` on `WidgetHandle` changes its return type:

```gleam
pub type DispatchResult {
  Completed(handle: WidgetHandle, result: Result(String, String))
  EffectPending(
    handle: WidgetHandle,
    perform: fn() -> Dynamic,
    resume: fn(Dynamic) -> DispatchResult,
  )
}
```

The `resume` closure captures the typed widget internals (model, fns, to_msg) so the agent never needs to know the concrete types. When `execute_cmd_loop` hits a `CmdEffect`, instead of running it inline, it returns `EffectPending` with the thunk and a continuation that will feed the result back into `update` and continue the loop.

### Public API

All fire-and-forget via `process.send`:
- `send_message(agent, text)` — wraps as `UserMessage`
- `send_command(agent, command)` — wraps as `UserCommand`
- `subscribe(agent, subject)` / `unsubscribe(agent, subject)`

No blocking `process.call` anywhere. The agent broadcasts `ServerEvent`s to subscribers.

### Key files to modify
- `backend/src/eddie/agent.gleam` — complete rewrite of message handling
- `backend/src/eddie/widget.gleam` — `dispatch_llm` returns `DispatchResult`, `execute_cmd_loop` returns `EffectPending` instead of running effects
- `backend/src/eddie/server.gleam` — remove `run_turn` call, relay `ClientCommand`s
- `backend/test/eddie/agent_test.gleam` — rewrite: send message, assert event sequence on subscriber

### Verification
- `cd backend && gleam test` — all tests pass
- Manual: send messages via WebSocket, observe event stream, verify user messages queue while LLM is processing

---

## Phase 4: Lustre SPA frontend

**Goal:** Build the frontend as a Lustre app that connects via WebSocket and renders domain events.

### Frontend structure

```
frontend/
├── gleam.toml
└── src/
    ├── eddie_frontend.gleam        # lustre.application(init, update, view)
    └── eddie_frontend/
        ├── model.gleam             # Model type (connection, chat, widget states, UI state)
        ├── msg.gleam               # Msg type (server events + user interactions)
        ├── update.gleam            # update function
        ├── view.gleam              # top-level view (layout, routing)
        ├── websocket.gleam         # WebSocket effect (connect, send, receive)
        ├── view/
        │   ├── chat.gleam          # chat area (messages, input, thinking indicator)
        │   ├── sidebar.gleam       # activity bar + panel container
        │   ├── goal.gleam          # goal panel
        │   ├── system_prompt.gleam # system prompt panel
        │   ├── file_explorer.gleam # file explorer panel
        │   ├── task.gleam          # task list panel
        │   └── token_usage.gleam   # token usage panel
        └── markdown.gleam          # markdown rendering (port from current JS)
```

### Frontend model

```gleam
pub type Model {
  Model(
    connection: ConnectionStatus,
    agents: Dict(String, AgentState),
    active_agent: Option(String),
    active_panel: Option(String),
    chat_input: String,
    thinking: Bool,
  )
}

pub type ConnectionStatus {
  Connecting
  Connected
  Disconnected
}

pub type AgentState {
  AgentState(
    goal: Option(String),
    system_prompt: String,
    tasks: Dict(Int, Task),
    task_order: List(Int),
    messages: List(ChatMessage),
    files: ...,
    directories: ...,
    token_usage: List(TokenRecord),
  )
}
```

### Frontend dependencies

```toml
[dependencies]
lustre = ">= 5.6.0 and < 6.0.0"
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.1.0 and < 4.0.0"
eddie_shared = { path = "../shared" }
```

### Backend serves the SPA

`server.gleam` updated:
- `GET /` serves an HTML shell that loads the compiled Lustre JS
- Static assets served from a build output directory
- WebSocket at `/ws` unchanged (already sends JSON events)

### Key files
- All new files in `frontend/src/`
- `backend/src/eddie/server.gleam` — serve static frontend
- Delete `backend/src/eddie/frontend.gleam`

### Verification
- `cd frontend && gleam build` — compiles to JS
- `task backend:run` — serves the SPA
- Manual: full end-to-end test in browser
- `cd backend && gleam test` — still passes

---

## Phase 5: Multi-agent support and cleanup

**Goal:** Frontend supports viewing/switching between multiple agents. Remove dead code, update docs.

### Frontend changes
- Agent selector in the UI (tab bar or dropdown)
- Each agent has its own WebSocket subscription
- `Model.agents` dict holds per-agent state
- Switching agents changes `active_agent`, renders that agent's state

### Cleanup
- Remove `backend/src/eddie/frontend.gleam` (if not already deleted)
- Update `CLAUDE.md` with new project structure
- Update `Taskfile.yml` with full monorepo tasks
- Update mdBook docs

### Verification
- All tests pass across all three projects
- End-to-end manual test with multiple agents
