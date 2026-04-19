import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should

import eddie/coerce
import eddie/message
import eddie/widget
import eddie/widgets/conversation_log

// ============================================================================
// Helpers
// ============================================================================

fn create_log() -> widget.WidgetHandle {
  conversation_log.create()
}

fn make_args(pairs: List(#(String, json.Json))) -> dynamic.Dynamic {
  let assert Ok(args) =
    json.object(pairs)
    |> json.to_string
    |> json.parse(decode.dynamic)
  args
}

fn nil_args() -> dynamic.Dynamic {
  make_args([])
}

fn dispatch_create_task(
  handle: widget.WidgetHandle,
  description: String,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "create_task",
    args: make_args([#("description", json.string(description))]),
  )
}

fn dispatch_start_task(
  handle: widget.WidgetHandle,
  task_id: Int,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "start_task",
    args: make_args([#("task_id", json.int(task_id))]),
  )
}

fn dispatch_task_memory(
  handle: widget.WidgetHandle,
  text: String,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "task_memory",
    args: make_args([#("text", json.string(text))]),
  )
}

fn dispatch_close_task(
  handle: widget.WidgetHandle,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "close_current_task",
    args: nil_args(),
  )
}

fn dispatch_pick_task(
  handle: widget.WidgetHandle,
  task_id: Int,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "task_pick",
    args: make_args([#("task_id", json.int(task_id))]),
  )
}

fn dispatch_remove_task(
  handle: widget.WidgetHandle,
  task_id: Int,
) -> #(widget.WidgetHandle, Result(String, String)) {
  widget.dispatch_llm(
    handle: handle,
    tool_name: "remove_task",
    args: make_args([#("task_id", json.int(task_id))]),
  )
}

fn send_user_message(
  handle: widget.WidgetHandle,
  text: String,
) -> widget.WidgetHandle {
  let msg = conversation_log.UserMessageReceived(text: text)
  let assert Ok(handle) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))
  handle
}

fn send_consume_picks(handle: widget.WidgetHandle) -> widget.WidgetHandle {
  let msg = conversation_log.ConsumePicks
  let assert Ok(handle) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))
  handle
}

fn send_response_received(
  handle: widget.WidgetHandle,
  response: message.Message,
  owning_task_id: option.Option(Int),
) -> widget.WidgetHandle {
  let msg =
    conversation_log.ResponseReceived(
      response: response,
      owning_task_id: owning_task_id,
    )
  let assert Ok(handle) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))
  handle
}

// ============================================================================
// Factory
// ============================================================================

pub fn create_conversation_log_test() {
  let handle = create_log()
  widget.id(handle) |> should.equal("conversation_log")
}

// ============================================================================
// Task lifecycle: create -> start -> memory -> close
// ============================================================================

pub fn create_task_test() {
  let handle = create_log()
  let #(handle, result) = dispatch_create_task(handle, "Audit auth")

  result |> should.equal(Ok("Created task 1: Audit auth"))

  // Tools should now include start_task (pending task exists)
  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "create_task") |> should.be_true
  list.contains(tool_names, "start_task") |> should.be_true
  list.contains(tool_names, "remove_task") |> should.be_true
}

pub fn start_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Do work")
  let #(handle, result) = dispatch_start_task(handle, 1)

  result |> should.equal(Ok("Started task 1: Do work"))

  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "task_memory") |> should.be_true
  // Should NOT have start_task (a task is active)
  list.contains(tool_names, "start_task") |> should.be_false
  // Should NOT have close_current_task (no memories yet)
  list.contains(tool_names, "close_current_task") |> should.be_false
}

pub fn task_memory_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Work")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(handle, result) = dispatch_task_memory(handle, "Found something")

  result |> should.equal(Ok("Memory recorded on task 1."))

  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "close_current_task") |> should.be_true
}

pub fn close_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Work")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(handle, _) = dispatch_task_memory(handle, "Memory 1")
  let #(handle, result) = dispatch_close_task(handle)

  result |> should.equal(Ok("Closed task 1."))

  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "task_pick") |> should.be_true
  list.contains(tool_names, "task_memory") |> should.be_false
  list.contains(tool_names, "close_current_task") |> should.be_false
}

// ============================================================================
// Protocol violations
// ============================================================================

pub fn start_when_active_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_create_task(handle, "Task B")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(_handle, result) = dispatch_start_task(handle, 2)

  case result {
    Ok(text) -> string.contains(text, "Cannot start task") |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn close_without_memory_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(_handle, result) = dispatch_close_task(handle)

  case result {
    Ok(text) -> string.contains(text, "Cannot close") |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn close_no_active_task_test() {
  let handle = create_log()
  let #(_handle, result) = dispatch_close_task(handle)

  case result {
    Ok(text) ->
      string.contains(text, "No task is in_progress") |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn memory_no_active_task_test() {
  let handle = create_log()
  let #(_handle, result) = dispatch_task_memory(handle, "Some memory")

  case result {
    Ok(text) -> string.contains(text, "no active task") |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn remove_non_pending_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(_handle, result) = dispatch_remove_task(handle, 1)

  case result {
    Ok(text) ->
      string.contains(text, "only pending tasks can be removed")
      |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn remove_pending_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, result) = dispatch_remove_task(handle, 1)

  result |> should.equal(Ok("Removed task 1."))

  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "start_task") |> should.be_false
  list.contains(tool_names, "remove_task") |> should.be_false
}

pub fn pick_non_done_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(_handle, result) = dispatch_pick_task(handle, 1)

  case result {
    Ok(text) -> string.contains(text, "not done") |> should.be_true
    Error(_) -> should.fail()
  }
}

pub fn start_non_pending_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let #(handle, _) = dispatch_task_memory(handle, "mem")
  let #(handle, _) = dispatch_close_task(handle)
  let #(_handle, result) = dispatch_start_task(handle, 1)

  case result {
    Ok(text) -> string.contains(text, "cannot be started") |> should.be_true
    Error(_) -> should.fail()
  }
}

// ============================================================================
// check_protocol
// ============================================================================

pub fn check_protocol_allows_task_management_test() {
  let model =
    conversation_log.ConversationLogModel(
      log: [],
      tasks: conversation_log.new_empty_tasks(),
      task_order: [],
      next_id: 1,
      active_task_id: None,
      picks_for_next_request: set.new(),
    )
  let free = set.new()

  conversation_log.check_protocol(
    model: model,
    tool_name: "create_task",
    protocol_free_tools: free,
  )
  |> should.equal(None)

  conversation_log.check_protocol(
    model: model,
    tool_name: "task_pick",
    protocol_free_tools: free,
  )
  |> should.equal(None)

  conversation_log.check_protocol(
    model: model,
    tool_name: "remove_task",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}

pub fn check_protocol_blocks_tool_outside_task_test() {
  let model =
    conversation_log.ConversationLogModel(
      log: [],
      tasks: conversation_log.new_empty_tasks(),
      task_order: [],
      next_id: 1,
      active_task_id: None,
      picks_for_next_request: set.new(),
    )
  let free = set.new()

  let result =
    conversation_log.check_protocol(
      model: model,
      tool_name: "open_file",
      protocol_free_tools: free,
    )
  result |> should.be_some
}

pub fn check_protocol_allows_protocol_free_tools_test() {
  let model =
    conversation_log.ConversationLogModel(
      log: [],
      tasks: conversation_log.new_empty_tasks(),
      task_order: [],
      next_id: 1,
      active_task_id: None,
      picks_for_next_request: set.new(),
    )
  let free = set.from_list(["set_goal"])

  conversation_log.check_protocol(
    model: model,
    tool_name: "set_goal",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}

pub fn check_protocol_allows_tool_inside_task_test() {
  let model =
    conversation_log.ConversationLogModel(
      log: [],
      tasks: conversation_log.new_empty_tasks(),
      task_order: [],
      next_id: 1,
      active_task_id: Some(1),
      picks_for_next_request: set.new(),
    )
  let free = set.new()

  conversation_log.check_protocol(
    model: model,
    tool_name: "open_file",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}

// ============================================================================
// view_messages — collapsed done tasks, picked expansion
// ============================================================================

pub fn view_messages_includes_protocol_rules_test() {
  let handle = create_log()
  let messages = widget.view_messages(handle)

  case messages {
    [message.Request(parts: [message.SystemPart(text)]), ..] ->
      string.contains(text, "Task Protocol") |> should.be_true
    _ -> should.fail()
  }
}

pub fn view_messages_collapses_done_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Audit auth")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let handle = send_user_message(handle, "check the middleware")
  let response =
    message.Response(parts: [message.TextPart("Looking at middleware")])
  let handle = send_response_received(handle, response, Some(1))
  let #(handle, _) = dispatch_task_memory(handle, "Found JWT issue")
  let #(handle, _) = dispatch_close_task(handle)

  let messages = widget.view_messages(handle)

  // Should contain a collapsed block with the memory
  let has_collapsed =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.SystemPart(text)]) ->
          string.contains(text, "Task: Audit auth")
          && string.contains(text, "Found JWT issue")
          && string.contains(text, "collapsed representation")
        _ -> False
      }
    })
  has_collapsed |> should.be_true

  // The raw user message should NOT appear (collapsed)
  let has_raw_user =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.UserPart(text)]) ->
          string.contains(text, "check the middleware")
        _ -> False
      }
    })
  has_raw_user |> should.be_false
}

pub fn view_messages_expands_picked_task_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let handle = send_user_message(handle, "hello")
  let #(handle, _) = dispatch_task_memory(handle, "Memory A")
  let #(handle, _) = dispatch_close_task(handle)
  let #(handle, _) = dispatch_pick_task(handle, 1)

  let messages = widget.view_messages(handle)

  let has_collapsed =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.SystemPart(text)]) ->
          string.contains(text, "Task: Task A")
          && string.contains(text, "viewing this task's full log")
        _ -> False
      }
    })
  has_collapsed |> should.be_true

  let has_raw_user =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.UserPart(text)]) ->
          string.contains(text, "hello")
        _ -> False
      }
    })
  has_raw_user |> should.be_true
}

pub fn consume_picks_clears_expansion_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let handle = send_user_message(handle, "hello")
  let #(handle, _) = dispatch_task_memory(handle, "Memory A")
  let #(handle, _) = dispatch_close_task(handle)
  let #(handle, _) = dispatch_pick_task(handle, 1)
  let handle = send_consume_picks(handle)

  let messages = widget.view_messages(handle)

  let has_raw_user =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.UserPart(text)]) ->
          string.contains(text, "hello")
        _ -> False
      }
    })
  has_raw_user |> should.be_false
}

pub fn view_messages_shows_open_tasks_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let #(handle, _) = dispatch_create_task(handle, "Task B")

  let messages = widget.view_messages(handle)
  let last = list.last(messages)

  case last {
    Ok(message.Request(parts: [message.UserPart(text)])) -> {
      string.contains(text, "Open tasks") |> should.be_true
      string.contains(text, "Task A") |> should.be_true
      string.contains(text, "Task B") |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn view_messages_in_progress_not_collapsed_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Active task")
  let #(handle, _) = dispatch_start_task(handle, 1)
  let handle = send_user_message(handle, "working on it")

  let messages = widget.view_messages(handle)

  let has_raw_user =
    list.any(messages, fn(msg) {
      case msg {
        message.Request(parts: [message.UserPart(text)]) ->
          string.contains(text, "working on it")
        _ -> False
      }
    })
  has_raw_user |> should.be_true
}

// ============================================================================
// from_llm unknown tool
// ============================================================================

pub fn unknown_llm_tool_returns_error_test() {
  let handle = create_log()
  let #(_handle, result) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "nonexistent",
      args: nil_args(),
    )

  result |> should.be_error
}

// ============================================================================
// from_ui events
// ============================================================================

pub fn ui_create_task_test() {
  let handle = create_log()
  let args = make_args([#("description", json.string("UI task"))])

  let #(handle, result) =
    widget.dispatch_ui(handle: handle, event_name: "create_task", args: args)

  result |> should.equal(Some(""))

  let tool_names =
    widget.view_tools(handle)
    |> list.map(fn(t) { t.name })
  list.contains(tool_names, "start_task") |> should.be_true
}

pub fn ui_empty_description_ignored_test() {
  let handle = create_log()
  let args = make_args([#("description", json.string("  "))])

  let #(_handle, result) =
    widget.dispatch_ui(handle: handle, event_name: "create_task", args: args)

  result |> should.equal(None)
}

pub fn ui_toggle_expanded_test() {
  let handle = create_log()
  let #(handle, _) = dispatch_create_task(handle, "Task A")
  let args = make_args([#("task_id", json.int(1))])

  let #(_handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "toggle_task_expanded",
      args: args,
    )

  result |> should.equal(Some(""))
}

// ============================================================================
// Multiple tasks with ID sequencing
// ============================================================================

pub fn task_ids_increment_test() {
  let handle = create_log()
  let #(handle, result1) = dispatch_create_task(handle, "First")
  let #(_handle, result2) = dispatch_create_task(handle, "Second")

  result1 |> should.equal(Ok("Created task 1: First"))
  result2 |> should.equal(Ok("Created task 2: Second"))
}
