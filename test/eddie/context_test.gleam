import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd
import eddie/context
import eddie/message
import eddie/tool
import eddie/widget
import eddie/widgets/conversation_log
import eddie/widgets/system_prompt

// ============================================================================
// Helpers
// ============================================================================

fn make_args(pairs: List(#(String, json.Json))) -> Dynamic {
  let assert Ok(args) =
    json.object(pairs)
    |> json.to_string
    |> json.parse(decode.dynamic)
  args
}

fn nil_args() -> Dynamic {
  make_args([])
}

fn create_default_context() -> context.Context {
  let sp = system_prompt.create(text: "You are a test agent.")
  let log = conversation_log.init()
  context.new(system_prompt: sp, children: [], conversation_log: log)
}

fn create_context_with_counter() -> context.Context {
  let sp = system_prompt.create(text: "Test agent.")
  let counter = create_counter()
  let log = conversation_log.init()
  context.new(system_prompt: sp, children: [counter], conversation_log: log)
}

// ============================================================================
// Minimal test widget: counter (same pattern as widget_test.gleam)
// ============================================================================

type CounterModel {
  CounterModel(count: Int)
}

type CounterMsg {
  Increment
  Decrement
}

fn counter_update(
  model: CounterModel,
  msg: CounterMsg,
) -> #(CounterModel, cmd.Cmd(CounterMsg)) {
  case msg {
    Increment -> #(
      CounterModel(count: model.count + 1),
      cmd.CmdToolResult(
        "Incremented to " <> counter_int_to_string(model.count + 1),
      ),
    )
    Decrement -> #(
      CounterModel(count: model.count - 1),
      cmd.CmdToolResult(
        "Decremented to " <> counter_int_to_string(model.count - 1),
      ),
    )
  }
}

fn counter_int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    _ -> "other"
  }
}

fn counter_view_messages(model: CounterModel) -> List(message.Message) {
  [
    message.Request(parts: [
      message.SystemPart("Counter: " <> counter_int_to_string(model.count)),
    ]),
  ]
}

fn counter_view_tools(_model: CounterModel) -> List(tool.ToolDefinition) {
  let schema =
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([])),
    ])
  let assert Ok(td) =
    tool.new(
      name: "increment",
      description: "Increment the counter",
      parameters_json: schema,
    )
  [td]
}

fn counter_view_html(model: CounterModel) -> Element(Nil) {
  html.div([], [html.text("Count: " <> counter_int_to_string(model.count))])
}

fn counter_from_llm(
  _model: CounterModel,
  tool_name: String,
  _args: Dynamic,
) -> Result(CounterMsg, String) {
  case tool_name {
    "increment" -> Ok(Increment)
    "decrement" -> Ok(Decrement)
    _ -> Error("Unknown tool: " <> tool_name)
  }
}

fn counter_from_ui(
  _model: CounterModel,
  event_name: String,
  _args: Dynamic,
) -> option.Option(CounterMsg) {
  case event_name {
    "increment" -> Some(Increment)
    "decrement" -> Some(Decrement)
    _ -> None
  }
}

fn create_counter() -> widget.WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "counter",
    model: CounterModel(count: 0),
    update: counter_update,
    view_messages: counter_view_messages,
    view_tools: counter_view_tools,
    view_html: counter_view_html,
    from_llm: counter_from_llm,
    from_ui: counter_from_ui,
    frontend_tools: set.from_list(["increment", "decrement"]),
    protocol_free_tools: set.new(),
  ))
}

/// A protocol-free counter for testing tools callable without active task.
fn create_protocol_free_counter() -> widget.WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "free_counter",
    model: CounterModel(count: 0),
    update: counter_update,
    view_messages: counter_view_messages,
    view_tools: counter_view_tools,
    view_html: counter_view_html,
    from_llm: counter_from_llm,
    from_ui: counter_from_ui,
    frontend_tools: set.from_list(["increment", "decrement"]),
    protocol_free_tools: set.from_list(["increment"]),
  ))
}

// ============================================================================
// Tests: message composition
// ============================================================================

pub fn view_messages_includes_system_prompt_test() {
  let ctx = create_default_context()
  let messages = context.view_messages(context: ctx)

  // First message should be the system prompt
  case messages {
    [message.Request(parts: [message.SystemPart(text)]), ..] ->
      string.contains(text, "test agent")
    _ -> False
  }
  |> should.be_true
}

pub fn view_messages_includes_conversation_log_protocol_test() {
  let ctx = create_default_context()
  let messages = context.view_messages(context: ctx)

  // Second message should be the task protocol rules from conversation_log
  case messages {
    [_, message.Request(parts: [message.SystemPart(text)]), ..] ->
      string.contains(text, "Task Protocol")
    _ -> False
  }
  |> should.be_true
}

pub fn view_messages_order_system_children_log_test() {
  let ctx = create_context_with_counter()
  let messages = context.view_messages(context: ctx)

  // Should have: system_prompt, counter state, protocol rules
  list.length(messages) |> should.equal(3)

  // System prompt first
  case list.first(messages) {
    Ok(message.Request(parts: [message.SystemPart(text)])) ->
      string.contains(text, "Test agent")
    _ -> False
  }
  |> should.be_true

  // Counter state in the middle
  case messages {
    [_, message.Request(parts: [message.SystemPart(counter_text)]), ..] ->
      string.contains(counter_text, "Counter: 0")
    _ -> False
  }
  |> should.be_true
}

// ============================================================================
// Tests: tool composition
// ============================================================================

pub fn view_tools_includes_conversation_log_tools_test() {
  let ctx = create_default_context()
  let tools = context.view_tools(context: ctx)
  let tool_names = list.map(tools, fn(t) { t.name })

  // Should include create_task at minimum
  list.contains(tool_names, "create_task") |> should.be_true
}

pub fn view_tools_includes_child_tools_test() {
  let ctx = create_context_with_counter()
  let tools = context.view_tools(context: ctx)
  let tool_names = list.map(tools, fn(t) { t.name })

  // Should include both counter and conversation_log tools
  list.contains(tool_names, "increment") |> should.be_true
  list.contains(tool_names, "create_task") |> should.be_true
}

// ============================================================================
// Tests: tool dispatch routing
// ============================================================================

pub fn handle_tool_call_routes_to_conversation_log_test() {
  let ctx = create_default_context()

  // create_task is a conversation_log tool
  let #(ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "create_task",
      args: make_args([#("description", json.string("Test task"))]),
      tool_call_id: "tc1",
    )

  result |> should.be_ok

  // Should now have start_task available
  let tools = context.view_tools(context: ctx)
  let tool_names = list.map(tools, fn(t) { t.name })
  list.contains(tool_names, "start_task") |> should.be_true
}

pub fn handle_tool_call_routes_to_child_widget_test() {
  let ctx = create_context_with_counter()

  // First create and start a task (protocol requires active task)
  let #(ctx, _) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "create_task",
      args: make_args([#("description", json.string("test"))]),
      tool_call_id: "tc1",
    )
  let #(ctx, _) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "start_task",
      args: make_args([#("task_id", json.int(1))]),
      tool_call_id: "tc2",
    )

  // Now dispatch to the counter widget
  let #(_ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "increment",
      args: nil_args(),
      tool_call_id: "tc3",
    )

  case result {
    Ok(text) -> string.contains(text, "Incremented")
    Error(_) -> False
  }
  |> should.be_true
}

pub fn handle_tool_call_unknown_tool_test() {
  let ctx = create_default_context()

  // create+start task first
  let #(ctx, _) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "create_task",
      args: make_args([#("description", json.string("test"))]),
      tool_call_id: "tc1",
    )
  let #(ctx, _) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "start_task",
      args: make_args([#("task_id", json.int(1))]),
      tool_call_id: "tc2",
    )

  let #(_ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "nonexistent_tool",
      args: nil_args(),
      tool_call_id: "tc3",
    )

  case result {
    Error(msg) -> string.contains(msg, "Unknown tool")
    Ok(_) -> False
  }
  |> should.be_true
}

// ============================================================================
// Tests: protocol enforcement
// ============================================================================

pub fn protocol_rejects_tool_outside_task_test() {
  let ctx = create_context_with_counter()

  // No active task — should reject non-task tools
  let #(_ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "increment",
      args: nil_args(),
      tool_call_id: "tc1",
    )

  case result {
    Error(msg) -> string.contains(msg, "outside a task")
    Ok(_) -> False
  }
  |> should.be_true
}

pub fn protocol_allows_task_management_without_active_task_test() {
  let ctx = create_default_context()

  // create_task should always be allowed
  let #(_ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "create_task",
      args: make_args([#("description", json.string("test"))]),
      tool_call_id: "tc1",
    )

  result |> should.be_ok
}

pub fn protocol_allows_protocol_free_tools_without_task_test() {
  let sp = system_prompt.create(text: "Test.")
  let counter = create_protocol_free_counter()
  let log = conversation_log.init()
  let ctx =
    context.new(system_prompt: sp, children: [counter], conversation_log: log)

  // increment is protocol-free for this counter
  let #(_ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "increment",
      args: nil_args(),
      tool_call_id: "tc1",
    )

  result |> should.be_ok
}

// ============================================================================
// Tests: user message handling
// ============================================================================

pub fn add_user_message_appears_in_view_messages_test() {
  let ctx = create_default_context()
  let ctx = context.add_user_message(context: ctx, text: "Hello!")
  let messages = context.view_messages(context: ctx)

  let has_user_msg =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.UserPart(text)]) -> text == "Hello!"
        _ -> False
      }
    })

  has_user_msg |> should.be_true
}

// ============================================================================
// Tests: response recording
// ============================================================================

pub fn add_response_appears_in_view_messages_test() {
  let ctx = create_default_context()
  let response =
    message.Response(parts: [message.TextPart("I can help with that.")])
  let ctx = context.add_response(context: ctx, response: response)
  let messages = context.view_messages(context: ctx)

  let has_response =
    list.any(messages, fn(msg) {
      case msg {
        message.Response(parts: [message.TextPart(text)]) ->
          text == "I can help with that."
        _ -> False
      }
    })

  has_response |> should.be_true
}

// ============================================================================
// Tests: UI event dispatch
// ============================================================================

pub fn handle_widget_event_dispatches_to_children_test() {
  let ctx = create_context_with_counter()

  // Dispatch increment via UI
  let ctx =
    context.handle_widget_event(
      context: ctx,
      event_name: "increment",
      args: nil_args(),
    )

  // Counter should now show 1 in its messages
  let messages = context.view_messages(context: ctx)
  let has_counter_1 =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.SystemPart(text)]) ->
          string.contains(text, "Counter: 1")
        _ -> False
      }
    })

  has_counter_1 |> should.be_true
}

// ============================================================================
// Tests: changed_html
// ============================================================================

pub fn changed_html_detects_no_change_test() {
  let ctx = create_default_context()
  let changes = context.changed_html(old: ctx, new: ctx)
  changes |> should.equal([])
}

pub fn changed_html_detects_child_change_test() {
  let ctx = create_context_with_counter()

  // Dispatch increment via UI to change counter HTML
  let new_ctx =
    context.handle_widget_event(
      context: ctx,
      event_name: "increment",
      args: nil_args(),
    )

  let changes = context.changed_html(old: ctx, new: new_ctx)

  // Counter widget should have changed
  let changed_ids = list.map(changes, fn(pair) { pair.0 })
  list.contains(changed_ids, "counter") |> should.be_true
}

// ============================================================================
// Tests: accessors
// ============================================================================

pub fn system_prompt_accessor_test() {
  let ctx = create_default_context()
  let sp = context.system_prompt(context: ctx)
  widget.id(sp) |> should.equal("system_prompt")
}

pub fn children_accessor_test() {
  let ctx = create_context_with_counter()
  let kids = context.children(context: ctx)
  list.length(kids) |> should.equal(1)
}

pub fn log_accessor_test() {
  let ctx = create_default_context()
  let log = context.log(context: ctx)
  // The log should have no owning task id initially
  conversation_log.owning_task_id(log: log) |> should.equal(None)
}

// ============================================================================
// Tests: full task lifecycle through context
// ============================================================================

pub fn full_task_lifecycle_through_context_test() {
  let ctx = create_default_context()

  // Create task
  let #(ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "create_task",
      args: make_args([#("description", json.string("Fix the bug"))]),
      tool_call_id: "tc1",
    )
  result |> should.be_ok

  // Start task
  let #(ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "start_task",
      args: make_args([#("task_id", json.int(1))]),
      tool_call_id: "tc2",
    )
  result |> should.be_ok

  // Simulate LLM response and tool results being recorded
  let response =
    message.Response(parts: [
      message.ToolCallPart("task_memory", "{}", "tc3"),
    ])
  let ctx = context.add_response(context: ctx, response: response)

  // Record memory
  let #(ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "task_memory",
      args: make_args([#("text", json.string("Found the bug in auth.gleam"))]),
      tool_call_id: "tc3",
    )
  result |> should.be_ok

  // Record tool results
  let tool_results =
    message.Request(parts: [
      message.ToolReturnPart("task_memory", "Memory recorded on task 1.", "tc3"),
    ])
  let ctx = context.add_tool_results(context: ctx, request: tool_results)

  // Close task
  let #(ctx, result) =
    context.handle_tool_call(
      context: ctx,
      tool_name: "close_current_task",
      args: nil_args(),
      tool_call_id: "tc4",
    )
  result |> should.be_ok

  // Verify task is collapsed in view_messages — the collapsed block
  // contains the task description and "Task summary"
  let messages = context.view_messages(context: ctx)
  let has_task_summary =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.SystemPart(text)]) ->
          string.contains(text, "Fix the bug")
          && string.contains(text, "Task summary")
        _ -> False
      }
    })

  has_task_summary |> should.be_true
}
