import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd
import eddie/coerce
import eddie_shared/message
import eddie/tool
import eddie/widget

// ============================================================================
// A minimal test widget: a counter with increment/decrement
// ============================================================================

type CounterModel {
  CounterModel(count: Int)
}

type CounterMsg {
  Increment
  Decrement
  SetCount(Int)
}

fn counter_update(
  model: CounterModel,
  msg: CounterMsg,
) -> #(CounterModel, cmd.Cmd(CounterMsg)) {
  case msg {
    Increment -> #(CounterModel(count: model.count + 1), cmd.CmdNone)
    Decrement -> #(CounterModel(count: model.count - 1), cmd.CmdNone)
    SetCount(n) -> #(
      CounterModel(count: n),
      cmd.CmdToolResult("Count set to " <> int_to_string(n)),
    )
  }
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    _ -> "other"
  }
}

fn counter_view_messages(model: CounterModel) -> List(message.Message) {
  [
    message.Request(parts: [
      message.SystemPart("Counter is at " <> int_to_string(model.count) <> "."),
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
  html.div([], [html.text("Count: " <> int_to_string(model.count))])
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

fn nil_dynamic() -> Dynamic {
  coerce.unsafe_coerce(Nil)
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

// ============================================================================
// Tests
// ============================================================================

pub fn widget_id_test() {
  let handle = create_counter()
  widget.id(handle) |> should.equal("counter")
}

pub fn view_messages_returns_initial_state_test() {
  let handle = create_counter()
  let messages = widget.view_messages(handle)

  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 0.")
}

pub fn view_tools_returns_tool_definitions_test() {
  let handle = create_counter()
  let tools = widget.view_tools(handle)

  case tools {
    [td] -> td.name
    _ -> ""
  }
  |> should.equal("increment")
}

pub fn dispatch_llm_increments_counter_test() {
  let handle = create_counter()

  let #(handle, result) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "increment",
      args: nil_dynamic(),
    )

  // CmdNone → Ok("")
  result |> should.equal(Ok(""))

  // Model should now be 1
  let messages = widget.view_messages(handle)
  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 1.")
}

pub fn dispatch_llm_unknown_tool_returns_error_test() {
  let handle = create_counter()

  let #(_handle, result) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "unknown_tool",
      args: nil_dynamic(),
    )

  result |> should.equal(Error("Unknown tool: unknown_tool"))
}

pub fn dispatch_llm_with_tool_result_test() {
  let custom_handle =
    widget.create(widget.WidgetConfig(
      id: "custom_counter",
      model: CounterModel(count: 0),
      update: counter_update,
      view_messages: counter_view_messages,
      view_tools: counter_view_tools,
      view_html: counter_view_html,
      from_llm: fn(_model, tool_name, _args) {
        case tool_name {
          "set_count" -> Ok(SetCount(3))
          _ -> Error("Unknown tool")
        }
      },
      from_ui: counter_from_ui,
      frontend_tools: set.from_list(["increment", "decrement"]),
      protocol_free_tools: set.new(),
    ))

  let #(handle, result) =
    widget.dispatch_llm(
      handle: custom_handle,
      tool_name: "set_count",
      args: nil_dynamic(),
    )

  // CmdToolResult("Count set to 3")
  result |> should.equal(Ok("Count set to 3"))

  // Model should be at 3
  let messages = widget.view_messages(handle)
  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 3.")
}

pub fn dispatch_ui_handles_frontend_tool_test() {
  let handle = create_counter()

  let #(handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "increment",
      args: nil_dynamic(),
    )

  result |> should.equal(Some(""))

  // Model should be at 1
  let messages = widget.view_messages(handle)
  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 1.")
}

pub fn dispatch_ui_rejects_non_frontend_tool_test() {
  let handle = create_counter()

  let #(_handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "not_a_frontend_tool",
      args: nil_dynamic(),
    )

  result |> should.equal(None)
}

pub fn send_updates_model_test() {
  let handle = create_counter()

  // Send an Increment directly (bypassing anticorruption layers)
  let assert Ok(handle) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(Increment))

  let messages = widget.view_messages(handle)
  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 1.")
}

pub fn multiple_dispatches_accumulate_state_test() {
  let handle = create_counter()

  // Increment 3 times
  let #(handle, _) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "increment",
      args: nil_dynamic(),
    )
  let #(handle, _) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "increment",
      args: nil_dynamic(),
    )
  let #(handle, _) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "increment",
      args: nil_dynamic(),
    )

  let messages = widget.view_messages(handle)
  case messages {
    [message.Request(parts: [message.SystemPart(text)])] -> text
    _ -> ""
  }
  |> should.equal("Counter is at 3.")
}

pub fn frontend_tools_accessor_test() {
  let handle = create_counter()
  let tools = widget.frontend_tools(handle)

  set.contains(tools, "increment") |> should.be_true
  set.contains(tools, "decrement") |> should.be_true
  set.contains(tools, "unknown") |> should.be_false
}

pub fn protocol_free_tools_accessor_test() {
  let handle = create_counter()
  let tools = widget.protocol_free_tools(handle)

  set.size(tools) |> should.equal(0)
}
