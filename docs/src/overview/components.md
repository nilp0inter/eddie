# Components

## Agent and Server (Phase 4)

### `eddie/agent`

Reactive OTP actor that owns the agent state and manages the LLM turn loop. The agent never blocks — LLM calls and tool effects are spawned as async processes that send results back as actor messages. User messages arriving during a turn are queued and processed after the current turn completes.

- **`AgentConfig(llm_config, system_prompt)`** — configuration passed at start
- **`AgentConfigOverride(model, api_base, system_prompt)`** — partial overrides for child agents (all fields `Option`). API key is always inherited
- **`merge_config(parent, override)`** — produces a child `AgentConfig` from a parent config and an override (None fields inherit from parent)
- **`AgentMessage`** — opaque message type with eleven variants:
  - `UserMessage(text, reply_to)` — user message with optional reply Subject
  - `GetState(reply_to)` — return current Context for inspection
  - `GetCurrentState(reply_to)` — return current widget state as a JSON-encoded `ServerEvent` list
  - `Subscribe(subscriber)` / `Unsubscribe(subscriber)` — register/unregister for state update notifications
  - `DispatchEvent(event_name, args_json)` — forward browser widget events
  - `LlmResponse(response)` / `LlmError(reason)` — from spawned LLM call process
  - `ToolEffectResult(call_id, data)` / `ToolEffectCrashed(call_id, reason)` — from spawned effect process
  - `SetSelf(subject)` — agent learns its own Subject during init
- **`TurnResult`** — `TurnSuccess(text)` | `TurnError(reason)`
- **`start(config)`** — creates a Context with default widgets, starts the actor, sends `SetSelf`, returns `Result(Subject(AgentMessage), StartError)`
- **`start_with_send_fn(config, send_fn)`** — same but with an injectable HTTP sender for testing
- **`run_turn(subject, text, timeout)`** — convenience wrapper: sends `UserMessage` with a reply Subject, blocks the caller via `process.call` (the agent processes asynchronously)
- **`send_message(subject, text)`** — fire-and-forget, no reply
- **`get_current_state(subject, timeout)`** — returns the current widget state as a JSON-encoded `ServerEvent` list (used to populate the frontend on initial WebSocket connection)

**Reactive turn internals:**

The agent reacts to messages based on its current data rather than following a synchronous loop. The turn lifecycle is capped at 25 iterations:

1. `UserMessage` arrives — if idle, add to context, broadcast events, call `start_llm_call`; if busy, queue in `pending_user_messages`
2. `start_llm_call` — compose messages and tools from Context, build HTTP request via `llm.build_request`, spawn a process to call `send_fn`, set `llm_in_flight = True`
3. `LlmResponse` arrives — parse response, record token usage, add to context, notify subscribers
4. If tool calls: dispatch each through `context.handle_tool_call` — completed tools are collected as `ToolReturnPart`s immediately; pending effects (`ToolEffectPending`) are spawned as async processes with resume continuations stored in `pending_effects`
5. When all effects complete (`pending_effects` empty): record tool results in conversation log, increment iteration, call `start_llm_call` for the next round
6. If text only: call `complete_turn` — broadcast `TurnCompleted`, reply to caller, drain next queued user message

**Agent state bookkeeping:**

- `llm_in_flight: Bool` — whether an LLM HTTP request is in flight
- `pending_user_messages: List(#(String, Option(Subject(TurnResult))))` — queued user messages with optional reply Subjects
- `pending_effects: Dict(String, EffectContinuation)` — in-flight tool effects keyed by call ID, each holding tool metadata and a `resume` closure
- `collected_tool_parts: List(MessagePart)` — tool results collected during a dispatch round, recorded as a single message when all effects complete
- `current_reply_to: Option(Subject(TurnResult))` — the reply Subject for the current turn's caller
- `iteration: Int` — current turn iteration (reset to 0 for each user message)

**Default widget tree:** `build_context` creates a Context with the system prompt, goal, file explorer, and token usage widgets as children, plus the conversation log.

**Subscriber notification:**

After each state mutation (user message added, response recorded, tool calls dispatched, tool results recorded), the agent computes `context.changed_state(old, new)` — which compares each widget's `view_state` output using structural equality — and sends the resulting `ServerEvent` list as a JSON-encoded string to all subscriber Subjects. This is a fire-and-forget push — subscribers are WebSocket handler processes that forward the JSON to the browser.

During tool dispatch, the agent sends `ToolCallStarted` and `ToolCallCompleted` `ServerEvent`s to subscribers, giving visibility into the agent's actions during a turn. `TurnStarted` and `TurnCompleted` are also broadcast through the subscriber mechanism. All notifications use the same JSON-encoded `ServerEvent` list format defined in `eddie_shared/protocol`.

### `eddie/server` and `eddie/frontend`

Mist HTTP and WebSocket server (`server.gleam`) plus a minimal browser frontend (`frontend.gleam`). The server is thin glue between the browser and the agent actor; the frontend module holds a temporary event-logging page that displays raw JSON domain events (a Lustre SPA is planned for Phase 4).

- **`ServerConfig(port)`** — listening port configuration
- **`start(config, agent)`** — starts mist, returns `Result(Started(Supervisor), StartError)`

**Routes:**

| Method | Path | Behaviour |
|---|---|---|
| `GET` | `/` | Serves the event-logging frontend |
| `GET` | `/ws` | WebSocket upgrade |
| `*` | `*` | 404 |

**WebSocket protocol:**

Each WebSocket connection is a separate BEAM process. On init, it creates a Subject for state updates (`Subject(String)`) and builds a Selector mapping it to `StateUpdate`. The connection subscribes to the agent for state updates, then immediately sends the current widget state via `agent.get_current_state` so that the frontend is populated on first load (without this, the frontend would remain empty until the first state mutation).

*Client → Server messages (JSON over WebSocket):*

| Key | Payload | Effect |
|---|---|---|
| `user_input` | `{"user_input": "text"}` | Calls `agent.send_message` (fire-and-forget) |
| `widget_event` | `{"widget_event": {"event_name": "...", "args_json": "..."}}` | Forwards to `agent.dispatch_event` |

Turn lifecycle events (`TurnStarted`, `TurnCompleted`) flow through the subscriber mechanism — the server does not need to track turn state separately.

*Server → Client messages:*

All server-to-client messages are JSON-encoded arrays of `ServerEvent` objects (defined in `eddie_shared/protocol`). Each event has a `"type"` field identifying the variant. Key event types:

| Event type | Purpose |
|---|---|
| `system_prompt_updated` | System prompt text changed |
| `goal_updated` | Goal set or cleared |
| `tokens_used` | Token usage for a request |
| `file_explorer_updated` | Open directories and files changed |
| `task_created`, `task_status_changed` | Task lifecycle events |
| `conversation_appended` | New log item (user message, response, tool results) |
| `tool_call_started`, `tool_call_completed` | Tool call progress during a turn |
| `turn_started`, `turn_completed` | Turn lifecycle (thinking indicator) |
| `agent_error` | Unrecoverable agent error |

**Frontend template (`eddie/frontend`):**

The `frontend.index_html()` function returns a minimal event-logging page. It connects via WebSocket, parses incoming JSON `ServerEvent` arrays, and displays each event with its type tag in a scrollable log. A text input allows sending user messages. This is a temporary stub — the full UI will be a Lustre SPA (Phase 4).

No build step, no external dependencies.

### `eddie` (entry point)

Application entry point. Reads configuration from environment variables, creates the agent and server, then sleeps forever (the BEAM scheduler keeps the actor and server alive).

| Env var | Required | Default | Purpose |
|---|---|---|---|
| `OPENROUTER_API_KEY` | Yes | — | LLM API key |
| `OPENROUTER_API_BASE` | No | `https://openrouter.ai/api/v1` | LLM API base URL |
| `EDDIE_MODEL` | No | `anthropic/claude-sonnet-4` | Model identifier |
| `EDDIE_PORT` | No | `8080` | HTTP listening port |

### `eddie/agent_tree` (Phase 6)

Manages hierarchical parent-child agent relationships. Each agent in the tree is an independent OTP actor with its own context and turn loop.

- **`AgentTree`** — opaque type holding the root agent, root config, children dict, and send_fn
- **`start(config)` / `start_with_send_fn(config, send_fn)`** — creates a tree with a root agent
- **`spawn_child(tree, id, override)`** — starts a child agent with `merge_config(root_config, override)`, returns `Result(AgentTree, SpawnError)`
- **`SpawnError`** — `ChildAlreadyExists(id)` | `ChildStartFailed(StartError)`
- **`get_child(tree, id)`** — looks up a child by ID
- **`root(tree)` / `children(tree)`** — accessors

Children share the parent's `send_fn` (HTTP sender) and API key. The tree does not use OTP supervision — each child is a standalone actor started with `agent.start_with_send_fn`. There is no automatic restart or health monitoring (see [technical debt](../decisions/tech-debt.md)).

## Widgets (Phase 2 + Phase 6)

### `eddie/widgets/system_prompt`

Identity and framing text for the agent. The simplest widget — holds a single text string yielded as a `SystemPart` to the LLM.

- **Model:** `SystemPromptModel(text: String)`
- **Messages:** `SetSystemPrompt(text)` | `ResetSystemPrompt`
- **LLM tools:** none — UI-only widget
- **Frontend events:** `set_system_prompt` (carries `{text: "..."}`) and `reset_system_prompt`
- **`view_state`:** `[SystemPromptUpdated(text: model.text)]`
- **Factory:** `create(text:)` or `create_default()` (default text establishes the Eddie identity and workflow instructions)

The update function is trivial: `SetSystemPrompt` replaces the text, `ResetSystemPrompt` reverts to the default. Both return `CmdNone` since there's no LLM to respond to.

### `eddie/widgets/conversation_log` and `eddie/widgets/task_protocol`

Task-partitioned conversation history with memory management. The most complex widget — manages the full task lifecycle and controls what the LLM sees in its context window. The task types and protocol enforcement logic live in a separate `task_protocol` module.

**Core concept:** the conversation is partitioned by **tasks**. A task moves through `Pending → InProgress → Done`. At most one task can be `InProgress` at any time. When a task closes, its full conversation span (tool calls, results, intermediate responses) collapses to just the task description and its **memories** — short LLM-authored summaries recorded during the task. The LLM can request one-shot re-expansion of a done task via `task_pick`.

**Types (defined in `task_protocol`):**

- `TaskStatus` — `Pending` | `InProgress` | `Done`
- `Task(id, description, status, memories, ui_expanded)` — memories stored as reversed list (prepend during update, reverse when viewing)
- `LogItem` — `UserMessageItem` | `ResponseItem` | `ToolResultsItem`, each carrying an `owning_task_id`
- `ConversationLogModel` — `log`, `tasks` dict, `task_order`, `next_id`, `active_task_id`, `picks_for_next_request` set

**Messages (14 variants):**

| Message | Source | Purpose |
|---|---|---|
| `CreateTask` | LLM / UI | Plan a unit of work |
| `StartTask` | LLM / UI | Begin work (sets `active_task_id`) |
| `TaskMemoryAppend` | LLM / UI | Record a finding (append-only while in progress) |
| `CloseCurrentTask` | LLM / UI | Finish task (requires ≥1 memory) |
| `PickTask` | LLM / UI | Expand done task's log for next request only |
| `RemoveTask` | LLM / UI | Delete a pending task (frozen once started) |
| `EditMemory` | UI | Modify an existing memory |
| `RemoveMemory` | UI | Delete a memory |
| `ToggleTaskExpanded` | UI | Visual toggle (no effect on LLM view) |
| `UpdateTaskStatus` | UI | Checkbox-driven transitions (delegates to Start/Close logic) |
| `UserMessageReceived` | Internal | Sent via `send()` to log user input |
| `ResponseReceived` | Internal | Sent via `send()` to log LLM response |
| `ToolResultsReceived` | Internal | Sent via `send()` to log tool results |
| `ConsumePicks` | Internal | Clear picks after a request/response round-trip |

**LLM tools (conditional availability):**

| Tool | Available when |
|---|---|
| `create_task` | Always |
| `remove_task` | Any pending task exists |
| `task_pick` | Any done task exists |
| `start_task` | No active task AND any pending task exists |
| `task_memory` | A task is in progress |
| `close_current_task` | A task is in progress AND it has ≥1 memory |

**Task protocol enforcement (in `task_protocol`):**

`task_protocol.check(active_task_id, tasks, tool_name, protocol_free_tools)` returns `Some(error_message)` if a tool call violates the protocol, `None` if allowed. The conversation log delegates to this via `check_protocol`, and the Context compositor (Phase 3) calls it before dispatching any tool call. Task management tools (`create_task`, `remove_task`, `task_pick`) are always allowed. All other tools require an active task unless they appear in the `protocol_free_tools` set.

The task protocol rules (`task_protocol.rules`) are injected as a `SystemPart` at the start of `view_messages`, instructing the LLM on the lifecycle, memory discipline, and constraints.

**`view_messages` collapsing logic:**

Log items are walked in chronological order, grouped by consecutive `owning_task_id`. Each group is rendered as:
- **No task** → raw messages (user prompts, responses, tool results)
- **In-progress task** → raw messages (full visibility while working)
- **Done task** → collapsed block (task description + memories only), unless picked for expansion
- **Picked done task** → collapsed block + raw messages (one-shot expansion)

An "Open tasks" block listing pending and in-progress tasks is appended at the end.

**`view_state`** produces `TaskCreated` events for each task and `ConversationAppended` events for each log item (as `LogItemSnapshot` variants: `UserMessageSnapshot`, `ResponseSnapshot`, `ToolResultsSnapshot`).

**Factory:** `create()` — returns a `WidgetHandle` with an empty model. For Context's use, `init()` returns a typed `ConversationLog` opaque type with direct dispatch, protocol checking, and owning task ID access (see [trade-off card](../decisions/tradeoffs/04-typed-conversation-log-in-context.md)).

### `eddie/widgets/goal` (Phase 6)

Protocol-free goal tracking. Both the LLM and the browser can set or clear the goal at any time, without needing an active task.

- **Model:** `GoalModel(text: Option(String))`
- **Messages:** `SetGoal(goal, initiator)` | `ClearGoal(initiator)` — both carry `Initiator` to determine whether to return a tool result
- **LLM tools:** `set_goal` (string `goal` parameter) and `clear_goal` (no parameters) — both protocol-free
- **Frontend events:** `set_goal` and `clear_goal`
- **Views:** `view_messages` yields a `UserPart` with `## Goal\n{text}` or `## Goal\nNo goal set`; `view_state` produces `[GoalUpdated(text: model.text)]`
- **Factory:** `create(text:)` with `Option(String)`, or `create_default()` for no initial goal

### `eddie/widgets/file_explorer` (Phase 6)

Filesystem navigation using `CmdEffect` for IO operations. All tools are protocol-free. Uses `simplifile` for directory listing and file reading.

- **Model:** `FileExplorerModel(open_directories, open_files)` — `OpenDirectory(path, entries, listing_text)`, files as `List(#(String, String))`
- **Messages:**
  - IO triggers: `OpenDirectoryRequested(path)`, `ReadFileRequested(path)` — produce `CmdEffect` that runs the IO and feeds a result message back into update
  - IO results: `DirectoryOpened(path, entries, listing_text)`, `DirectoryOpenError(error)`, `FileRead(path, content)`, `FileReadError(error)`
  - Close: `CloseDirectory(path, initiator)`, `CloseReadFile(path, initiator)`
- **LLM tools:** `open_directory` (path defaults to `"."`), `close_directory`, `read_file`, `close_read_file` — all protocol-free
- **Frontend events:** same four tool names
- **Views:** `view_messages` yields a markdown listing of open directories and file contents; `view_state` produces `[FileExplorerUpdated(directories: [...], files: [...])]` with `DirectorySnapshot` and `FileSnapshot` protocol types
- **IO pattern:** `CmdEffect(perform: fn() { coerce.unsafe_coerce(do_open_directory(path)) }, to_msg: coerce.unsafe_coerce)` — the perform closure runs the real IO, returns a `FileExplorerMsg` coerced to `Dynamic`, and `to_msg` coerces it back. Re-opening the same path refreshes the listing
- **Factory:** `create()`

### `eddie/widgets/token_usage` (Phase 6)

Display-only token tracking. No LLM tools or messages — receives data via `widget.send()` from the agent turn loop after each LLM response.

- **Model:** `TokenUsageModel(records: List(TokenRecord))` — records stored reversed (prepend), reversed for display. `TokenRecord(request_number, input_tokens, output_tokens)`
- **Messages:** `UsageRecorded(input_tokens, output_tokens)` — a single message variant
- **Views:** `view_messages` returns `[]`, `view_tools` returns `[]`; `view_state` produces `[TokensUsed(input, output)]` for each record in chronological order
- **Integration:** the agent's `record_token_usage` function finds the token_usage widget by ID in the children list and sends a `UsageRecorded` message via `widget.send` after each parsed LLM response
- **Factory:** `create()`

## Structured Output (Phase 5)

### `eddie/structured_output`

Sans-IO structured output extraction — a mini pydantic-ai for Eddie. Extracts typed Gleam values from LLM responses using sextant schemas, with automatic retry on validation failure.

- **`OutputSchema(a)`** — wraps a `sextant.JsonSchema(a)` with a name and description. The sextant schema provides both JSON Schema generation (for the LLM) and validation/decoding (for the response)
- **`Strategy`** — selects how the schema is presented to the LLM:
  - `ToolCallStrategy` — registers a fake tool whose parameters ARE the schema; the LLM "calls" the tool and Eddie validates the arguments
  - `NativeStrategy` — sends the schema as `response_format` (json_schema); the LLM returns JSON text and Eddie validates it
- **`extract(config, messages, output, strategy, max_retries, send_fn)`** — the main entry point. Takes an injectable `send_fn` (same pattern as `agent.gleam`) for testability. Returns `Result(a, StructuredOutputError)`
- **`StructuredOutputError`** — `SendError` | `ApiError` | `EmptyResponse` | `MaxRetriesExceeded(last_errors)` | `UnexpectedResponse`

**Extraction pipeline:**

1. Build a glopenai request with either a tool definition (tool-call) or response_format (native)
2. Send via the injected `send_fn`
3. Parse the glopenai response; route to strategy-specific validation
4. Parse JSON (stripping markdown fences if present), validate with `sextant.run`
5. On success: return `Ok(value)`. On validation failure: build structured error feedback and retry
6. Retry messages differ by strategy: tool-call echoes back the failed tool call + `RetryPart`; native sends a `UserPart` with error details

**Utilities:**

- `strip_markdown_fences` — handles `` ```json `` and `` ``` `` wrapping that some models add around JSON output
- `strip_dollar_schema` — removes the `$schema` key from sextant-generated JSON Schema (tool parameters and response_format schemas don't include it)
- `encode_dynamic` — Erlang FFI (`eddie_ffi.dynamic_to_json`) to re-encode a decoded Dynamic value back to `json.Json`, matching glopenai's approach

## Context and LLM (Phase 3)

### `eddie/context`

The root compositor — the glue between widgets and the agent loop. Holds a system prompt widget, zero or more child widgets, and a typed conversation log. Orchestrates tool dispatch, message composition, and protocol enforcement.

- **`Context`** — opaque type holding the widget tree plus a `tool_owners` map (tool name → widget ID) and a collected `protocol_free_tools` set
- **`new(system_prompt, children, conversation_log)`** — builds the context and scans all widgets to populate `tool_owners`
- **`view_messages`** — composes messages from all widgets in order: system prompt → children → conversation log
- **`view_tools`** — collects tool definitions from all widgets
- **`add_user_message` / `add_response` / `add_tool_results`** — record items in the conversation log, tagged with the current owning task ID
- **`consume_picks`** — clears one-shot task expansions after a request/response round-trip
- **`handle_tool_call(context, tool_name, args, tool_call_id)`** — enforces the task protocol via `conversation_log.protocol_check`, then routes to the owning widget. Returns `ToolDispatchResult`: either `ToolCompleted(context, result)` or `ToolEffectPending(context, tool_name, tool_call_id, owner_id, perform, resume)`
- **`replace_widget(context, owner_id, handle)`** — replaces a widget handle by owner ID. Used by the agent to insert updated handles after async effects complete
- **`handle_widget_event`** — dispatches browser UI events to all widgets (no protocol enforcement)
- **`current_state(context)`** — returns the current state events for all widgets as a flat `List(ServerEvent)` (used for initial WebSocket connect)
- **`changed_state(old, new)`** — compares each widget's `view_state` output using structural equality, returns events from widgets whose state differs

The conversation log is stored as a typed `ConversationLog` (not a `WidgetHandle`) so Context can access protocol checking and the owning task ID directly. See [trade-off card](../decisions/tradeoffs/04-typed-conversation-log-in-context.md) for the rationale.

### `eddie/llm`

Sans-IO LLM client bridge. Converts between Eddie types and glopenai types without performing any network IO.

- **`LlmConfig(api_base, api_key, model)`** — configuration for the LLM endpoint
- **`TokenUsage(input_tokens, output_tokens)`** — token counts extracted from the LLM response
- **`build_request(config, messages, tools)`** — converts Eddie `Message` and `ToolDefinition` lists into a glopenai `CreateChatCompletionRequest`, returns a ready-to-send `Request(String)`
- **`parse_response(response)`** — parses a glopenai API response into an Eddie `Message` and optional token usage, returns `Result(#(Message, Option(TokenUsage)), LlmError)`. The usage is extracted from glopenai's `CompletionUsage` (prompt_tokens → input_tokens, completion_tokens → output_tokens)
- **`LlmError`** — `ApiError(GlopenaiError)` | `EmptyResponse`

### `eddie/http`

Thin HTTP execution layer — the only module that performs actual network IO.

- **`send(request)`** — sends an `Request(String)` via gleam_httpc, returns `Result(Response(String), HttpError)`
- **`HttpError`** — wraps `httpc.HttpError`

## Core types (Phase 1)

### `eddie/cmd`

Side-effect descriptors for the Elm-architecture widget system.

- `Initiator` — who triggered a message: `LLM` (expects tool result back) or `UI` (silent)
- `Cmd(msg)` — describes what should happen after an update:
  - `CmdNone` — no effect
  - `CmdToolResult(text)` — respond to the LLM with the given text
  - `CmdEffect(perform, to_msg)` — run an IO thunk, convert result to a msg, feed back into update
- `for_initiator(initiator, text)` — returns `CmdToolResult` for LLM, `CmdNone` for UI

### `eddie/message`

Eddie's own message types, decoupled from glopenai's wire format. Widgets produce and consume these; the LLM client module handles conversion.

- `MessagePart` — a piece of content within a message:
  - `SystemPart` — system prompt
  - `UserPart` — user text
  - `TextPart` — model-generated text
  - `ToolCallPart` — model requesting a tool call (carries `tool_name`, `arguments_json`, `tool_call_id`)
  - `ToolReturnPart` — result of a tool call sent back to the model
  - `RetryPart` — retry prompt after validation failure
- `Message` — either `Request(parts)` (going to model) or `Response(parts)` (from model)
- `to_chat_messages` / `from_chat_response` — bidirectional conversion with glopenai's `ChatMessage`

### `eddie/tool`

Tool definitions that widgets expose to the LLM.

- `ToolDefinition(name, description, parameters_schema)` — `parameters_schema` is `Dynamic` because glopenai's `FunctionObject.parameters` expects it
- `new(name, description, parameters_json)` — returns `Result(ToolDefinition, ToolError)`, converting `json.Json` to `Dynamic` internally
- `to_chat_tool` — converts to glopenai's `ChatCompletionTool`

### `eddie/widget`

The central abstraction. Defines both the typed configuration and the type-erased handle.

**`WidgetConfig(model, msg)`** — all the functions that define a widget:
- `update: fn(model, msg) -> #(model, Cmd(msg))`
- `view_messages: fn(model) -> List(Message)`
- `view_tools: fn(model) -> List(ToolDefinition)`
- `view_state: fn(model) -> List(ServerEvent)`
- `from_llm: fn(model, String, Dynamic) -> Result(msg, String)` — anticorruption layer for LLM tool calls
- `from_ui: fn(model, String, Dynamic) -> Option(msg)` — anticorruption layer for browser events
- `frontend_tools: Set(String)` — tool names callable from the browser
- `protocol_free_tools: Set(String)` — tool names exempt from task protocol

**`WidgetHandle`** — opaque, type-erased via closures. Context holds a list of these. Internally uses a `WidgetFns` record to bundle the function table, avoiding excessive parameter threading. Key operations:
- `dispatch_llm(handle, tool_name, args)` — runs from_llm -> update -> Cmd loop, returns `DispatchResult`
- `dispatch_ui(handle, event_name, args)` — checks frontend_tools, runs from_ui -> update -> Cmd loop (resolves effects synchronously)
- `send(handle, msg)` — direct dispatch, must produce CmdNone
- `view_messages`, `view_tools`, `view_state` — produce widget output
- `resolve(dispatch_result)` — runs a `DispatchResult` to completion synchronously (used by `dispatch_ui` and tests)
- `dispatch_result_handle(dispatch_result)` — extracts the handle from either `Completed` or `EffectPending`

**`DispatchResult`** — the return type of `dispatch_llm`:
- `Completed(handle, result)` — the tool call finished; `result` is `Ok(text)` or `Error(message)`
- `EffectPending(handle, perform, resume)` — a `CmdEffect` needs to run asynchronously; `perform` is the effect thunk, `resume` is a continuation that accepts the effect's result and returns the next `DispatchResult`

When the agent dispatches an LLM tool call, the widget's Cmd loop yields `EffectPending` for `CmdEffect` commands instead of running them inline. The agent spawns a process for the effect and stores the `resume` continuation. When the effect completes, the agent calls `resume(data)` to continue the Cmd loop. For UI events (`dispatch_ui`), effects are resolved synchronously via `resolve`.

### `eddie/coerce`

Unsafe type coercion for the type erasure boundary. Uses an Erlang FFI identity function (`eddie_ffi.erl`) to convert `Dynamic` back to the concrete `msg` type inside `WidgetHandle.send`. This is safe because `send` is only called by code that knows the concrete type.
