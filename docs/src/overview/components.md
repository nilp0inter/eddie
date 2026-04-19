# Components

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
