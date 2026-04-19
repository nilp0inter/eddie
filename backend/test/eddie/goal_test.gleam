import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should

import eddie_shared/message
import eddie/widget

import eddie/widgets/goal

// ============================================================================
// Factory tests
// ============================================================================

pub fn create_default_has_no_goal_test() {
  let handle = goal.create_default()
  widget.id(handle)
  |> should.equal("goal")
}

pub fn create_with_text_test() {
  let handle = goal.create(text: Some("Build a widget system"))
  let messages = widget.view_messages(handle)
  let assert [message.Request(parts: [message.UserPart(text)])] = messages
  text
  |> should.equal("## Goal\nBuild a widget system")
}

pub fn create_without_text_test() {
  let handle = goal.create(text: None)
  let messages = widget.view_messages(handle)
  let assert [message.Request(parts: [message.UserPart(text)])] = messages
  text
  |> should.equal("## Goal\nNo goal set")
}

// ============================================================================
// LLM tool dispatch tests
// ============================================================================

pub fn set_goal_via_llm_test() {
  let handle = goal.create_default()
  let args =
    json.to_string(json.object([#("goal", json.string("Ship v2"))]))
    |> json.parse(dynamic_decoder())
    |> unwrap_ok
  let #(updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "set_goal", args: args)
  result
  |> should.equal(Ok("Goal set: Ship v2"))

  // Verify the goal text is now in messages
  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  text
  |> should.equal("## Goal\nShip v2")
}

pub fn clear_goal_via_llm_test() {
  let handle = goal.create(text: Some("Old goal"))
  let args = empty_args()
  let #(updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "clear_goal", args: args)
  result
  |> should.equal(Ok("Goal cleared"))

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  text
  |> should.equal("## Goal\nNo goal set")
}

pub fn unknown_tool_via_llm_test() {
  let handle = goal.create_default()
  let args = empty_args()
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "unknown", args: args)
  result
  |> should.equal(Error("Goal: unknown tool 'unknown'"))
}

pub fn set_goal_missing_field_via_llm_test() {
  let handle = goal.create_default()
  let args = empty_args()
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "set_goal", args: args)
  result
  |> should.equal(Error("set_goal: missing or invalid 'goal' field"))
}

// ============================================================================
// UI event dispatch tests
// ============================================================================

pub fn set_goal_via_ui_test() {
  let handle = goal.create_default()
  let args =
    json.to_string(json.object([#("goal", json.string("UI goal"))]))
    |> json.parse(dynamic_decoder())
    |> unwrap_ok
  let #(updated, result) =
    widget.dispatch_ui(handle: handle, event_name: "set_goal", args: args)
  // UI dispatch returns None (CmdNone -> no tool result -> Ok("") -> Some(""))
  result
  |> should.equal(Some(""))

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  text
  |> should.equal("## Goal\nUI goal")
}

pub fn clear_goal_via_ui_test() {
  let handle = goal.create(text: Some("Existing goal"))
  let args = empty_args()
  let #(updated, _result) =
    widget.dispatch_ui(handle: handle, event_name: "clear_goal", args: args)

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  text
  |> should.equal("## Goal\nNo goal set")
}

pub fn unknown_event_via_ui_test() {
  let handle = goal.create_default()
  let args = empty_args()
  let #(_updated, result) =
    widget.dispatch_ui(handle: handle, event_name: "unknown", args: args)
  result
  |> should.equal(None)
}

// ============================================================================
// Protocol-free verification
// ============================================================================

pub fn protocol_free_tools_test() {
  let handle = goal.create_default()
  let free = widget.protocol_free_tools(handle)
  set.contains(free, "set_goal")
  |> should.be_true
  set.contains(free, "clear_goal")
  |> should.be_true
}

pub fn frontend_tools_test() {
  let handle = goal.create_default()
  let frontend = widget.frontend_tools(handle)
  set.contains(frontend, "set_goal")
  |> should.be_true
  set.contains(frontend, "clear_goal")
  |> should.be_true
}

// ============================================================================
// View tools test
// ============================================================================

pub fn view_tools_returns_two_tools_test() {
  let handle = goal.create_default()
  let tools = widget.view_tools(handle)
  let assert [set_tool, clear_tool] = tools
  set_tool.name
  |> should.equal("set_goal")
  clear_tool.name
  |> should.equal("clear_goal")
}

// ============================================================================
// Helpers
// ============================================================================

import gleam/dynamic/decode

fn dynamic_decoder() -> decode.Decoder(dynamic.Dynamic) {
  decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })
}

fn unwrap_ok(result: Result(a, b)) -> a {
  let assert Ok(value) = result
  value
}

fn empty_args() -> dynamic.Dynamic {
  json.to_string(json.object([]))
  |> json.parse(dynamic_decoder())
  |> unwrap_ok
}
