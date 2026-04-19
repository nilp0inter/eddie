# Components

## Widgets (Phase 2)

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

**Factory:** `create()` — returns a `WidgetHandle` with an empty model.

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
