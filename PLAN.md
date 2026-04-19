# Eddie Implementation Plan

## Context

Eddie is a Gleam reimplementation of Calipso — an Elm-architecture widget system that builds shared context between a user and an AI agent. Each widget has a model, typed messages, a pure update function, and three views: LLM messages, LLM tools, and browser HTML.

Key differences from Calipso:
- **OTP multi-agent** (not mono-agent) with hierarchical agent spawning
- **Lustre** for both server-side widget HTML (element types) and client-side SPA
- **glopenai** (sans-IO) + **gleam_httpc** for LLM calls
- **sextant** for JSON Schema generation/validation (structured output)
- Tool-call + native structured output strategies with retry loop

Reference files:
- `reference/calipso/` — Python reference implementation
- `reference/glopenai/` — Gleam OpenAI client (hex.pm)
- `reference/sextant/` — Gleam JSON Schema library (hex.pm)
- `reference/pydantic-ai/structured-output-internals.md` — parsing spec

---

## Phase 1: Core Types and Widget Abstraction ✅

**Status:** Complete — 28 tests passing, glinter clean (1 expected unused_export for `view_html`).

**Implemented:**
- `src/eddie/cmd.gleam` — `Initiator` (LLM/UI), `Cmd(msg)` (CmdNone/CmdToolResult/CmdEffect), `for_initiator`
- `src/eddie/message.gleam` — `MessagePart`, `Message`, bidirectional glopenai conversion
- `src/eddie/tool.gleam` — `ToolDefinition`, `ToolError`, `new` (returns Result), `to_chat_tool`
- `src/eddie/widget.gleam` — `WidgetConfig(model, msg)`, `WidgetHandle` (opaque, type-erased via closures + `WidgetFns` bundle), `SendError`, full Cmd loop execution
- `src/eddie/coerce.gleam` + `src/eddie_ffi.erl` — unsafe coercion for type erasure boundary

**Key design decisions made during implementation:**
- `WidgetHandle` uses an internal `WidgetFns` record to bundle the function table, avoiding 10-parameter threading
- `tool.new` returns `Result(ToolDefinition, ToolError)` instead of panicking
- `widget.send` returns `Result(WidgetHandle, SendError)` instead of asserting CmdNone
- `CmdEffect` is executed synchronously within the Cmd loop (BEAM processes are lightweight)
- Args passed to `from_llm`/`from_ui` as `Dynamic` (parsed from JSON by the caller)
- All public functions use labelled arguments per glinter

**Dependencies added:** `gleam_json`, `lustre`, `glopenai`, `glinter` (dev)

---

## Phase 2: SystemPrompt and ConversationLog Widgets ✅

**Status:** Complete — 64 tests passing (28 Phase 1 + 36 Phase 2), glinter clean (expected warnings only).

**Implemented:**
- `src/eddie/widgets/system_prompt.gleam` — `SystemPromptModel`, `SetSystemPrompt`/`ResetSystemPrompt` msgs, `create(text:)`/`create_default()` factories, UI-only (no LLM tools), default text with Eddie identity
- `src/eddie/widgets/conversation_log.gleam` — Full task lifecycle (`Pending -> InProgress -> Done`), `ConversationLogModel` with reversed-list prepend strategy, 14 message types, 6 LLM tools (conditional availability based on state), `check_protocol` enforcement, `view_messages` with task collapsing/expansion, `from_llm`/`from_ui` anticorruption with `gleam/dynamic/decode`

**Key design decisions made during implementation:**
- Log and task_order use reversed lists (prepend during update, reverse during view) for efficient append
- Memories stored reversed internally, displayed in original order via `list.reverse`
- `check_protocol` extracted as a standalone public function (not embedded in dispatch) for Phase 3 Context to call
- `current_owning_task_id` exposed for Phase 3 Context to tag log items
- `from_ui` handlers extracted into named functions to reduce nesting
- `set_task` helper reduces boilerplate for task dict updates
- `decode_field_string`/`decode_field_int`/`decode_ui_int` helpers reduce decoder boilerplate
- `task_id_schema()` shared across tool definitions to avoid duplication
- Tool definitions constructed lazily per `view_tools` call (no module-level state)

**Tests cover:**
- SystemPrompt: create with custom/default text, view_messages, dispatch_llm error, set/reset via UI, unknown event
- ConversationLog: full task lifecycle (create → start → memory → close), protocol violations (start when active, close without memory, close no active task, memory no active task, remove non-pending, pick non-done, start non-pending), view_messages (protocol rules, collapsing, picked expansion, consume picks, open tasks block, in-progress not collapsed), from_llm/from_ui (unknown tool, UI create/toggle, empty description ignored), ID sequencing

---

## Phase 3: Context Compositor and LLM Client

**Goal:** Root compositor + glopenai bridge. The glue between widgets and LLM.

**Corresponds to:** `calipso/widgets/context.py`, `calipso/model.py`

### Files to create

**`src/eddie/context.gleam`** — Root compositor
- `Context(system_prompt, children, conversation_log, tool_owners)`
- `new(system_prompt, conversation_log, children) -> Context` — builds tool_owners map
- `view_messages(ctx) -> List(Message)` — composes from all widgets
- `view_tools(ctx) -> List(ToolDefinition)` — composes from all widgets
- `add_user_message(ctx, text) -> Context`
- `handle_tool_call(ctx, tool_name, args, tool_call_id) -> #(Context, Result(String, String))` — dispatches to owner, enforces protocol
- `handle_widget_event(ctx, event_name, args) -> Context` — UI dispatch, bypasses protocol
- `changed_html(old_ctx, new_ctx) -> List(#(String, Element(Nil)))` — diff detection

**`src/eddie/llm.gleam`** — LLM client bridge
- `LlmConfig(api_base, api_key, model)`
- `build_request(config, messages, tools) -> Request(String)` — uses glopenai builders
- `parse_response(Response(String)) -> Result(Message, GlopenaiError)`

**`src/eddie/http.gleam`** — HTTP execution layer
- `send(Request(String)) -> Result(Response(String), HttpError)` — via gleam_httpc

### Dependencies to add
`gleam_httpc`, `gleam_http`

### Tests
- Context composes messages from all widgets in correct order
- Tool dispatch routes to correct owner
- Protocol enforcement: rejects tool calls outside active task
- LLM request building produces valid JSON
- LLM response parsing extracts text and tool calls
- Integration: build request from context, mock response, parse it

---

## Phase 4: Agent Loop, Web Server, and Lustre Frontend

**Goal:** First working end-to-end chat in the browser. Eddie is fully web — no CLI REPL. **MILESTONE 1.**

**Corresponds to:** `calipso/runner.py`, `calipso/server.py`, `calipso/static/index.html`

### Files to create

**`src/eddie/agent.gleam`** — Agent as OTP GenServer
- `AgentConfig(llm_config, system_prompt)`
- `AgentMessage`: `RunTurn(text, reply_to) | GetState(reply_to)`
- `TurnResult`: `TurnSuccess(text) | TurnError(reason)`
- `start(config) -> Result(Subject(AgentMessage), StartError)`

GenServer loop for `RunTurn`:
1. `context.add_user_message(text)`
2. Loop: compose messages+tools → `llm.build_request` → `http.send` → `llm.parse_response`
3. Extract tool calls from response
4. If text only → record response, reply with text
5. For each tool call → `context.handle_tool_call` → collect results
6. Record response + tool results in conversation log → continue loop

CmdEffect handling: agent process executes `perform()` synchronously, converts result via `to_msg`, feeds back to `update`. BEAM processes are lightweight so blocking is fine.

**`src/eddie/server.gleam`** — mist HTTP + WebSocket
- `ServerConfig(host, port)`
- `start(config, agent) -> Result(Nil, StartError)`
- Serves Lustre SPA at `/`, WebSocket at `/ws`
- On user input: `RunTurn` → agent, pushes updates back
- On widget event: dispatches to context
- Pushes changed widget HTML fragments over WebSocket

**`src/eddie.gleam`** — Application entry point (update existing)
- Starts the agent process with default widget tree
- Starts the mist web server
- No stdin/REPL — everything happens through the browser

**Frontend (JS target, separate compilation unit):**

**`src/eddie_frontend/app.gleam`** — Lustre SPA
- `Model(widgets_html, input_text, connected, thinking, agents)`
- `Msg`: `WebSocketMessage | InputChanged | SendMessage | SelectAgent | ...`
- VS Code-style layout: activity bar + side panel + chat area
- Agent list view → click → per-agent dashboard (like Calipso but with agent ID header)
- WebSocket connection for real-time updates

### Dependencies to add
`gleam_otp`, `gleam_erlang`, `mist`

### Tests
- Agent loop with mock LLM: send message, get response
- Multi-turn conversation history accumulates
- Tool call dispatch: LLM calls task tool, state transitions correctly
- CmdEffect execution within agent process
- Open browser, see chat interface
- Type message, get LLM response displayed
- Widget HTML updates during tool calls
- Multiple browser tabs (broadcast)

---

## Phase 5: Structured Output Layer

**Goal:** Mini pydantic-ai — tool-call + native structured output strategies with retry.

**Corresponds to:** `reference/pydantic-ai/structured-output-internals.md`

### Files to create

**`src/eddie/structured_output.gleam`**
- `OutputSchema(a)`: wraps `sextant.JsonSchema(a)` with name + description
- **Tool-call strategy**: register fake tool → LLM "calls" it → validate args with sextant → return typed value
- **Native strategy**: send schema as `response_format` → parse text response → validate
- `extract(config, messages, output, max_retries) -> Result(a, StructuredOutputError)`
- Retry loop: validation error → structured error feedback → re-request → re-validate

Uses:
- `sextant.to_json(schema)` to generate JSON Schema for tool parameters
- `sextant.run(data, schema)` to validate LLM response
- `glopenai/chat.with_response_format` for native strategy

### Dependencies to add
`sextant`

### Tests
- Define sextant schema, extract structured output via tool-call mock
- Retry: inject validation error, verify structured feedback sent, verify correction
- Native strategy: response_format in request, parse text response
- Edge cases: markdown fences, scalar wrapping

---

## Phase 6: Hierarchical Agents and Additional Widgets

**Goal:** Multi-agent spawning and remaining Calipso widgets.

### Files to create

**`src/eddie/agent_tree.gleam`** — Hierarchical agent management
- `AgentTree(root, children)` with OTP supervisor
- `spawn_child(parent, id, config_override) -> Result(AgentTree, StartError)`
- Config inheritance: child defaults to parent's LlmConfig, overrides specific fields

**`src/eddie/config.gleam`** — Config merge
- `AgentConfigOverride(model?, api_base?, system_prompt?)`
- `merge_config(parent, override) -> AgentConfig`

**`src/eddie/widgets/goal.gleam`** — Protocol-free goal widget
- Model: `GoalModel(text: Option(String))`
- Tools: `set_goal`, `clear_goal` (both LLM + UI, protocol-free)

**`src/eddie/widgets/token_usage.gleam`** — Display-only tracking
- Receives `UsageRecorded` via `send()` after each response

**`src/eddie/widgets/file_explorer.gleam`** — File system browsing
- Uses `CmdEffect` for directory listing / file reading IO

### Tests
- Parent spawns child, child inherits config
- Child config overrides work
- Goal set/clear, verify protocol-free (works without active task)
- File explorer: open/close directory, read file (with mocked effects)

---

## Dependency Summary

| Phase | New Dependencies |
|-------|-----------------|
| 1 | gleam_json, lustre, glopenai |
| 2 | — |
| 3 | gleam_httpc, gleam_http |
| 4 | gleam_otp, gleam_erlang, mist |
| 5 | sextant |
| 6 | — |

## Verification

After each phase, run `task tests:unit` to verify all tests pass. Key end-to-end checkpoints:

- **Phase 4 (Milestone 1):** `gleam run` → open browser → see agent list → click agent → chat with LLM in web UI
- **Phase 6:** spawn child agent from parent, observe child state in parent's dashboard
