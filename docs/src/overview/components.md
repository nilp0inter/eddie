# Components

## Agent and Server (Phase 4)

### `eddie/agent`

OTP actor that owns the agent state and runs the LLM turn loop. The actor processes one message at a time — the turn loop runs synchronously within the actor process, which is idiomatic for the BEAM (lightweight processes, no thread contention).

- **`AgentConfig(llm_config, system_prompt)`** — configuration passed at start
- **`AgentConfigOverride(model, api_base, system_prompt)`** — partial overrides for child agents (all fields `Option`). API key is always inherited
- **`merge_config(parent, override)`** — produces a child `AgentConfig` from a parent config and an override (None fields inherit from parent)
- **`AgentMessage`** — opaque message type with five variants:
  - `RunTurn(text, reply_to)` — user message triggers a full turn loop
  - `GetState(reply_to)` — return current Context for inspection
  - `Subscribe(subscriber)` / `Unsubscribe(subscriber)` — register/unregister for HTML update notifications
  - `DispatchEvent(event_name, args_json)` — forward browser widget events
- **`TurnResult`** — `TurnSuccess(text)` | `TurnError(reason)`
- **`start(config)`** — creates a Context with default widgets, starts the actor, returns `Result(Subject(AgentMessage), StartError)`
- **`start_with_send_fn(config, send_fn)`** — same but with an injectable HTTP sender for testing
- **`run_turn(subject, text, timeout)`** — convenience wrapper around `process.call`

**Turn loop internals:**

The recursive turn loop (`turn_loop → do_turn_step → handle_llm_response → dispatch_tool_calls → turn_loop`) is capped at 25 iterations. Each iteration:

1. Compose messages and tools from the Context
2. Build an HTTP request via `llm.build_request` and send via the injectable `send_fn`
3. Parse the response (extracting both the message and token usage data); send usage to the token_usage widget
4. Consume picks; record the response in the conversation log
5. If tool calls: dispatch each through `context.handle_tool_call`, collect `ToolReturnPart`s, record tool results, continue loop
6. If text only: extract text and return `TurnSuccess`

**Default widget tree:** `build_context` creates a Context with the system prompt, goal, file explorer, and token usage widgets as children, plus the conversation log.

**Subscriber notification:**

After each state mutation (user message added, response recorded, tool calls dispatched, tool results recorded), the agent computes `context.changed_html(old, new)` and wraps each changed widget's HTML in a `<div id="widget-{id}" data-swap-oob="true">` envelope. The concatenated HTML string is sent to all subscriber Subjects. This is a fire-and-forget push — subscribers are WebSocket handler processes that forward the HTML to the browser.

### `eddie/server`

Mist HTTP and WebSocket server. Thin glue between the browser and the agent actor.

- **`ServerConfig(port)`** — listening port configuration
- **`start(config, agent)`** — starts mist, returns `Result(Started(Supervisor), StartError)`

**Routes:**

| Method | Path | Behaviour |
|---|---|---|
| `GET` | `/` | Serves the inline HTML frontend |
| `GET` | `/ws` | WebSocket upgrade |
| `*` | `*` | 404 |

**WebSocket protocol:**

Each WebSocket connection is a separate BEAM process. On init, it creates two Subjects — one for HTML updates (`Subject(String)`), one for turn results (`Subject(TurnResult)`) — and builds a Selector that maps both to internal `WsCustomMessage` variants. The connection subscribes to the agent for HTML updates.

*Client → Server messages (JSON over WebSocket):*

| Key | Payload | Effect |
|---|---|---|
| `user_input` | `{"user_input": "text"}` | Spawns a helper process that calls `agent.run_turn` and sends the result to the turn result Subject |
| `widget_event` | `{"widget_event": {"event_name": "...", "args_json": "..."}}` | Forwards to `agent.dispatch_event` |

*Server → Client messages:*

| Type | Payload | Purpose |
|---|---|---|
| HTML fragments | Raw HTML with `data-swap-oob` divs | Widget state changes (pushed by agent subscriber) |
| `turn_start` | `{"type": "turn_start"}` | Enables thinking indicator in the browser |
| `turn_end` | `{"type": "turn_end", "success": bool, "text": "...", "error": "..."}` | Disables thinking indicator, displays response |

**Inline HTML frontend:**

The `index_html()` function returns a self-contained HTML page with embedded CSS and ~40 lines of JavaScript. Features: Catppuccin-themed chat interface, sidebar widget panels, WebSocket with auto-reconnect, manual DOM swap for OOB-tagged fragments, thinking indicator during turns. No build step, no external dependencies. This approach matches Calipso's htmx pattern but without the htmx library — just plain `element.innerHTML` replacement keyed by element ID.

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
- **Factory:** `create(text:)` or `create_default()` (default text establishes the Eddie identity and workflow instructions)

The update function is trivial: `SetSystemPrompt` replaces the text, `ResetSystemPrompt` reverts to the default. Both return `CmdNone` since there's no LLM to respond to.

### `eddie/widgets/conversation_log`

Task-partitioned conversation history with memory management. The most complex widget — manages the full task lifecycle and controls what the LLM sees in its context window.

**Core concept:** the conversation is partitioned by **tasks**. A task moves through `Pending → InProgress → Done`. At most one task can be `InProgress` at any time. When a task closes, its full conversation span (tool calls, results, intermediate responses) collapses to just the task description and its **memories** — short LLM-authored summaries recorded during the task. The LLM can request one-shot re-expansion of a done task via `task_pick`.

**Types:**

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

**Task protocol enforcement:**

`check_protocol(model, tool_name, protocol_free_tools)` returns `Some(error_message)` if a tool call violates the protocol, `None` if allowed. The Context compositor (Phase 3) will call this before dispatching any tool call. Task management tools (`create_task`, `remove_task`, `task_pick`) are always allowed. All other tools require an active task unless they appear in the `protocol_free_tools` set.

The task protocol rules are injected as a `SystemPart` at the start of `view_messages`, instructing the LLM on the lifecycle, memory discipline, and constraints.

**`view_messages` collapsing logic:**

Log items are walked in chronological order, grouped by consecutive `owning_task_id`. Each group is rendered as:
- **No task** → raw messages (user prompts, responses, tool results)
- **In-progress task** → raw messages (full visibility while working)
- **Done task** → collapsed block (task description + memories only), unless picked for expansion
- **Picked done task** → collapsed block + raw messages (one-shot expansion)

An "Open tasks" block listing pending and in-progress tasks is appended at the end.

**Factory:** `create()` — returns a `WidgetHandle` with an empty model. For Context's use, `init()` returns a typed `ConversationLog` opaque type with direct dispatch, protocol checking, and owning task ID access (see [trade-off card](../decisions/tradeoffs/04-typed-conversation-log-in-context.md)).

### `eddie/widgets/goal` (Phase 6)

Protocol-free goal tracking. Both the LLM and the browser can set or clear the goal at any time, without needing an active task.

- **Model:** `GoalModel(text: Option(String))`
- **Messages:** `SetGoal(goal, initiator)` | `ClearGoal(initiator)` — both carry `Initiator` to determine whether to return a tool result
- **LLM tools:** `set_goal` (string `goal` parameter) and `clear_goal` (no parameters) — both protocol-free
- **Frontend events:** `set_goal` and `clear_goal`
- **Views:** `view_messages` yields a `UserPart` with `## Goal\n{text}` or `## Goal\nNo goal set`; `view_html` renders a heading, content, input field, and buttons
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
- **Views:** `view_messages` yields a markdown listing of open directories and file contents; `view_html` renders directory trees and file previews
- **IO pattern:** `CmdEffect(perform: fn() { coerce.unsafe_coerce(do_open_directory(path)) }, to_msg: coerce.unsafe_coerce)` — the perform closure runs the real IO, returns a `FileExplorerMsg` coerced to `Dynamic`, and `to_msg` coerces it back. Re-opening the same path refreshes the listing
- **Factory:** `create()`

### `eddie/widgets/token_usage` (Phase 6)

Display-only token tracking. No LLM tools or messages — receives data via `widget.send()` from the agent turn loop after each LLM response.

- **Model:** `TokenUsageModel(records: List(TokenRecord))` — records stored reversed (prepend), reversed for display. `TokenRecord(request_number, input_tokens, output_tokens)`
- **Messages:** `UsageRecorded(input_tokens, output_tokens)` — a single message variant
- **Views:** `view_messages` returns `[]`, `view_tools` returns `[]`; `view_html` shows request count, total input/output tokens (with K/M suffix formatting), and the last 10 records
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
- **`handle_tool_call(context, tool_name, args, tool_call_id)`** — enforces the task protocol via `conversation_log.protocol_check`, then routes to the owning widget. Returns `#(Context, Result(String, String))`
- **`handle_widget_event`** — dispatches browser UI events to all widgets (no protocol enforcement)
- **`changed_html(old, new)`** — detects which widgets' HTML changed between two snapshots

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
- `view_html: fn(model) -> Element(Nil)`
- `from_llm: fn(model, String, Dynamic) -> Result(msg, String)` — anticorruption layer for LLM tool calls
- `from_ui: fn(model, String, Dynamic) -> Option(msg)` — anticorruption layer for browser events
- `frontend_tools: Set(String)` — tool names callable from the browser
- `protocol_free_tools: Set(String)` — tool names exempt from task protocol

**`WidgetHandle`** — opaque, type-erased via closures. Context holds a list of these. Internally uses a `WidgetFns` record to bundle the function table, avoiding excessive parameter threading. Key operations:
- `dispatch_llm(handle, tool_name, args)` — runs from_llm -> update -> Cmd loop
- `dispatch_ui(handle, event_name, args)` — checks frontend_tools, runs from_ui -> update -> Cmd loop
- `send(handle, msg)` — direct dispatch, must produce CmdNone
- `view_messages`, `view_tools`, `view_html` — produce widget output

The Cmd loop executes `CmdEffect` synchronously within the closure. This is safe because BEAM processes are lightweight and the agent GenServer (Phase 4) will own the execution context.

### `eddie/coerce`

Unsafe type coercion for the type erasure boundary. Uses an Erlang FFI identity function (`eddie_ffi.erl`) to convert `Dynamic` back to the concrete `msg` type inside `WidgetHandle.send`. This is safe because `send` is only called by code that knows the concrete type.
