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

## Phase 3: Non-blocking reactive agent ✅

**Status: Complete.**

The synchronous `do_run_turn` loop has been replaced with a reactive actor that never blocks. LLM calls and tool effects are spawned as async processes.

### What was done

**Widget infrastructure — `DispatchResult` type:**
- `widget.gleam`: `dispatch_llm` returns `DispatchResult` (either `Completed` or `EffectPending`) instead of running effects inline
- `execute_cmd_loop` yields `EffectPending` for `CmdEffect` instead of executing synchronously
- Added `resolve` function to run a `DispatchResult` to completion synchronously (used by `dispatch_ui` and tests)
- Added `dispatch_result_handle` to extract the handle from either variant

**Context — `ToolDispatchResult` type:**
- `context.gleam`: `handle_tool_call` returns `ToolDispatchResult` (either `ToolCompleted` or `ToolEffectPending`)
- Added `replace_widget` function for the agent to insert updated handles after async effects complete
- Added `wrap_dispatch_result` helper to convert widget-level results to context-level results

**Agent — reactive actor rewrite:**
- `agent.gleam`: Complete rewrite. New message variants: `LlmResponse`, `LlmError`, `ToolEffectResult`, `ToolEffectCrashed`, `SetSelf`
- New state fields: `self`, `llm_in_flight`, `pending_user_messages`, `pending_effects`, `collected_tool_parts`, `current_reply_to`, `iteration`
- LLM calls spawned via `process.spawn` — agent never blocks
- Tool effects spawned asynchronously with resume continuations
- User messages queued when agent is busy, drained after turn completes
- `run_turn` preserved as convenience API (caller blocks via `process.call`, agent processes asynchronously)
- Added `send_message` for fire-and-forget usage

**Server simplification:**
- `server.gleam`: Removed blocking `send_run_turn` helper, `TurnComplete` custom message, and `turn_result_to_json`
- User input now uses `agent.send_message` (fire-and-forget)
- TurnStarted/TurnCompleted flow through the subscriber mechanism

**Test updates:**
- All `widget.dispatch_llm` calls pipe through `widget.resolve`
- All `context.handle_tool_call` calls pattern match on `context.ToolCompleted`
- Agent tests unchanged (run_turn API preserved)

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

## Phase 4: Lustre SPA frontend ✅

**Status: Complete.**

Built a Lustre SPA that connects via WebSocket, decodes domain events, and renders a chat UI with sidebar panels.

### What was done

**Shared package — JSON decoders added:**
- `message.gleam`: `message_part_decoder`, `message_decoder`
- `task.gleam`: `status_decoder`
- `turn_result.gleam`: `decoder`
- `protocol.gleam`: `server_event_decoder`, `client_command_to_json`, `client_command_decoder`, plus decoders for all snapshot types (`task_snapshot_decoder`, `log_item_snapshot_decoder`, `directory_snapshot_decoder`, `file_snapshot_decoder`, `token_record_decoder`)
- 41 roundtrip tests in `shared/test/eddie_shared/protocol_test.gleam`

**Build tooling:**
- Added `esbuild` to Nix flake `ciPackages`
- Added `frontend:bundle` task to Taskfile (builds + bundles to `frontend/build/app.js`)
- Created `frontend/entrypoint.mjs` (version-independent esbuild entrypoint)
- Updated `backend:run` to depend on `frontend:bundle`

**Frontend SPA** (`frontend/src/eddie_frontend.gleam`):
- Single-module Lustre application following "life of a file" principle
- Uses `lustre_websocket` (v0.8.x) for WebSocket connection
- Model holds agent state (goal, tasks, log, directories, files, tokens)
- Folds all events from a WebSocket message into the model in a single update cycle
- Auto-reconnect on disconnect via timer effect
- Sidebar panels: Goal, Tasks, Files, Token Usage
- Chat view: user messages, assistant responses with tool call badges, collapsible tool results
- Thinking indicator with pulsing animation
- Catppuccin Mocha dark theme
- Small JS FFI for `setTimeout` and `scrollToBottom`

**Backend server updates:**
- `server.gleam`: Serves HTML shell at `GET /` with `<div id="app">` + `<script src="/app.js">`
- `GET /app.js` serves bundled frontend JS via `simplifile.read`
- `handle_client_message` now parses `ClientCommand` JSON via shared decoder
- `dispatch_client_command` maps `ClientCommand` variants to widget event dispatch
- Deleted `backend/src/eddie/frontend.gleam`

### Frontend structure

```
frontend/
├── gleam.toml               # JS target, lustre + lustre_websocket + eddie_shared
├── entrypoint.mjs           # esbuild entrypoint (imports and calls main)
└── src/
    ├── eddie_frontend.gleam  # Entire Lustre app (Model, Msg, init, update, view)
    └── eddie_frontend_ffi.mjs  # JS FFI (setTimeout, scrollToBottom)
```

---

## Phase 5: Multi-agent support and cleanup ✅

**Status: Complete.**

Multi-agent support added across the full stack. The server routes WebSocket connections per agent, the frontend supports agent switching via a tab bar, and `AgentTree` is now an OTP actor for runtime child spawning.

### What was done

**Shared package:**
- Added `AgentInfo(id, label)` type with JSON encoder/decoder to `protocol.gleam`
- Added roundtrip test for `AgentInfo`

**Agent config — `agent_id` field:**
- `AgentConfig` now includes `agent_id: String`
- `merge_config` takes `child_id` parameter — children get their own id
- Entry point sets `agent_id: "root"` for the root agent

**AgentTree — OTP actor rewrite:**
- `agent_tree.gleam` is now an OTP actor (was a plain value type)
- Messages: `GetRoot`, `GetAgent(id)`, `ListAgents`, `SpawnChild(id, label, override)`
- Public API via `process.call`: `root(tree)`, `get_agent(tree, id)`, `list_agents(tree)`, `spawn_child(tree, id, label, override)`
- Children can be spawned at runtime; the server always sees the latest state
- Children stored as `Dict(String, #(Subject(AgentMessage), String))` (subject + label)

**Server — per-agent WebSocket routing:**
- `start` now takes `tree: Subject(AgentTreeMessage)` instead of a single agent
- WebSocket path: `/ws/<agent_id>` (with `/ws` as backwards-compatible alias for root)
- `GET /agents` returns JSON list of `AgentInfo` for all agents
- WebSocket upgrade looks up agent by ID; returns 404 for unknown agents

**Entry point:**
- Creates `AgentTree` instead of a single agent
- Passes tree subject to server

**Frontend — multi-agent model:**
- Extracted `AgentState` type holding per-agent state (goal, tasks, log, files, tokens, thinking, tool calls)
- `Model.agents: Dict(String, AgentState)` caches state per agent
- `Model.active_agent: String` tracks selected agent
- `Model.agent_list: List(AgentInfo)` populated from `GET /agents` on init
- Agent tab bar in top bar — clicking switches WebSocket connection
- `SwitchAgent(id)` closes old WS, opens new to `/ws/<id>`
- JS FFI `fetch_json` added for agent list fetch

**Tests:**
- All agent tree tests updated for actor-based API (Subject instead of value)
- Added `get_root_by_id_test` and `list_agents_test`
- All test configs include `agent_id`
- Config merge tests verify `child_id` is applied

### Verification
- 165 backend tests pass, 46 shared tests pass
- `backend:lint` clean (0 errors)
- All packages formatted
