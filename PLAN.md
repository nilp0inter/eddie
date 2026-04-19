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

## Phase 3: Context Compositor and LLM Client ✅

**Status:** Complete — 93 tests passing (64 Phase 1+2 + 29 Phase 3), glinter clean (expected warnings only).

**Implemented:**
- `src/eddie/context.gleam` — Root compositor with opaque `Context` type, `new`, `view_messages`, `view_tools`, `add_user_message`, `add_response`, `add_tool_results`, `consume_picks`, `handle_tool_call` (with protocol enforcement), `handle_widget_event`, `changed_html`, accessors
- `src/eddie/llm.gleam` — Sans-IO LLM client bridge: `LlmConfig`, `build_request` (glopenai request building), `parse_response` (response parsing into Eddie types), `LlmError` type
- `src/eddie/http.gleam` — HTTP execution layer: `send` via gleam_httpc, `HttpError` type
- `src/eddie/widgets/conversation_log.gleam` — Added typed API: `ConversationLog` opaque type, `init`, `to_handle`, `protocol_check`, `owning_task_id`, `dispatch_tool`, `dispatch_event`, `send_msg`, `typed_view_messages`, `typed_view_tools`, `typed_view_html`

**Key design decisions made during implementation:**
- Context stores `ConversationLog` (typed) instead of `WidgetHandle` for the conversation log, giving it direct access to protocol checking and owning task id without breaking type erasure
- `ConversationLog` opaque type added to conversation_log module — wraps the model and provides typed dispatch/send functions, with its own Cmd loop implementation
- Tool owners map rebuilt after every state mutation to keep it in sync with conditional tool availability
- Conversation log tools always registered in tool_owners even when conditionally hidden from view_tools
- `changed_html` uses string comparison of rendered HTML to detect changes
- `llm.gleam` follows sans-IO pattern: builds glopenai `Request(String)`, parses `Response(String)` — no network IO

**Dependencies added:** `gleam_httpc`, `gleam_http`

**Tests cover:**
- Context: message composition order (system → children → log), tool composition, tool dispatch routing (to conversation_log, to child widgets, unknown tool error), protocol enforcement (rejects outside task, allows task management, allows protocol-free tools), user message recording, response recording, UI event dispatch, changed_html detection, accessors, full task lifecycle through context
- LLM: request building (method/path, auth header, model, messages, tools), response parsing (text-only, tool calls, empty choices, API errors)

---

## Phase 4: Agent Loop, Web Server, and Frontend ✅

**Status:** Complete — 98 tests passing (93 Phase 1-3 + 5 Phase 4), glinter clean (expected warnings only).

**Goal:** First working end-to-end chat in the browser. Eddie is fully web — no CLI REPL. **MILESTONE 1.**

**Corresponds to:** `calipso/runner.py`, `calipso/server.py`, `calipso/static/index.html`

**Implemented:**
- `src/eddie/agent.gleam` — OTP actor with `AgentConfig`, opaque `AgentMessage` (RunTurn/GetState/Subscribe/Unsubscribe/DispatchEvent), `TurnResult` (TurnSuccess/TurnError). Recursive turn loop with injectable `send_fn` for testability. Subscriber notification via `context.changed_html` + HTML fragment OOB wrapping.
- `src/eddie/server.gleam` — mist HTTP + WebSocket. Routes: `GET /` (inline HTML), `GET /ws` (WebSocket upgrade). WebSocket handler: Selector-based dual Subject (HTML updates + turn results). User input spawns helper process calling `agent.run_turn`. Widget events forwarded via `agent.dispatch_event`.
- `src/eddie.gleam` — Entry point: reads `OPENROUTER_API_KEY` (required), `OPENROUTER_API_BASE`, `EDDIE_MODEL`, `EDDIE_PORT` from env. Creates agent + mist server, sleeps forever.
- Inline HTML frontend (inside server.gleam): Catppuccin-themed chat UI with sidebar widget panels, WebSocket auto-reconnect, manual OOB swap (no htmx dependency), thinking indicator.
- `src/eddie_ffi.erl` — Added `get_env/1` for environment variable access.

**Key design decisions made during implementation:**
- Chose inline HTML + plain JS over Lustre SPA for Milestone 1 simplicity; Lustre SPA deferred to potential Phase 4b
- Agent uses `actor.new` directly (no supervision tree) — sufficient for single-agent Milestone 1
- Mock HTTP sender uses a response queue actor (separate process) since `process.receive` requires Subject ownership
- `json_to_dynamic` uses `decode.new_primitive_decoder` identity decoder to convert parsed JSON to Dynamic
- `send_run_turn` spawns a helper process to call blocking `agent.run_turn` without blocking the WebSocket handler
- AgentMessage is opaque — server interacts only through public API functions

**Dependencies added:** `gleam_otp`, `gleam_erlang`, `mist`

**Tests cover:**
- Simple text response (mock LLM returns text, verify TurnSuccess)
- Tool call dispatch (create_task tool call then text response)
- Full task lifecycle (create+start, memory, close, final text)
- HTTP error returns TurnError
- Subscriber receives HTML update notifications

---

## Phase 5: Structured Output Layer ✅

**Status:** Complete — 113 tests passing (98 Phase 1-4 + 15 Phase 5), glinter clean (expected warnings only).

**Goal:** Mini pydantic-ai — tool-call + native structured output strategies with retry.

**Corresponds to:** `reference/pydantic-ai/structured-output-internals.md`

**Implemented:**
- `src/eddie/structured_output.gleam` — Sans-IO structured output extraction with two strategies:
  - `OutputSchema(a)`: wraps `sextant.JsonSchema(a)` with name + description
  - `Strategy`: `ToolCallStrategy` (fake tool whose args are the schema) or `NativeStrategy` (response_format json_schema)
  - `extract(config, messages, output, strategy, max_retries, send_fn)` — main extraction function with injectable send_fn
  - `StructuredOutputError`: `SendError`, `ApiError`, `EmptyResponse`, `MaxRetriesExceeded`, `UnexpectedResponse`
  - Retry loop: validation failure → structured error feedback → re-request → re-validate
  - `strip_markdown_fences` utility for LLMs that wrap JSON in code fences
  - `strip_dollar_schema` strips the `$schema` key from sextant output for tool parameters
- `src/eddie_ffi.erl` — Added `dynamic_to_json/1` FFI for re-encoding Dynamic values to json.Json
- `test/eddie_test_ffi.erl` — Erlang atomics-based counter for sequencing mock responses in tests

**Key design decisions made during implementation:**
- Sans-IO pattern: `extract` takes a `send_fn` callback, same pattern as `agent.gleam` — no HTTP dependency
- Both strategies share the same `parse_and_validate` → `AttemptResult` → retry pipeline
- Tool-call retry echoes back the failed tool call + RetryPart to keep conversation well-formed
- Native retry sends error as UserPart (no tool call to echo)
- `strip_dollar_schema` uses `encode_dynamic` FFI (same as glopenai's `codec.dynamic_to_json`) to re-serialize dict entries
- Markdown fence stripping handles `\`\`\`json` and `\`\`\`` patterns (common with some models)

**Dependencies added:** `sextant`

**Tests cover:**
- Tool-call strategy: valid extraction, markdown fences, scalar wrapping (single-field object)
- Native strategy: valid extraction, no text returns UnexpectedResponse
- Retry loop: validation error then correction (tool-call and native), max retries exceeded with error details
- Error cases: send error, empty response, tool-call with text-only response, native with tool-call response
- Existing messages forwarded correctly

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
