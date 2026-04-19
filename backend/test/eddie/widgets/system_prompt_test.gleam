import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

import eddie/coerce
import eddie/widget
import eddie/widgets/system_prompt
import eddie_shared/message

// ============================================================================
// Helpers
// ============================================================================

fn nil_dynamic() {
  coerce.unsafe_coerce(Nil)
}

// ============================================================================
// Factory and initial state
// ============================================================================

pub fn create_with_custom_text_test() {
  let handle = system_prompt.create(text: "Custom prompt")
  widget.id(handle) |> should.equal("system_prompt")
}

pub fn create_default_has_text_test() {
  let handle = system_prompt.create_default()
  let messages = widget.view_messages(handle)

  case messages {
    [message.Request(parts: [message.SystemPart(text)])] ->
      string.contains(text, "Eddie") |> should.be_true
    _ -> should.fail()
  }
}

// ============================================================================
// view_messages
// ============================================================================

pub fn view_messages_returns_system_part_test() {
  let handle = system_prompt.create(text: "Hello world")
  let messages = widget.view_messages(handle)

  case messages {
    [message.Request(parts: [message.SystemPart(text)])] ->
      text |> should.equal("Hello world")
    _ -> should.fail()
  }
}

// ============================================================================
// view_tools (empty)
// ============================================================================

pub fn view_tools_is_empty_test() {
  let handle = system_prompt.create(text: "test")
  widget.view_tools(handle) |> should.equal([])
}

// ============================================================================
// dispatch_llm (always errors — no LLM tools)
// ============================================================================

pub fn dispatch_llm_returns_error_test() {
  let handle = system_prompt.create(text: "test")

  let #(_handle, result) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "anything",
      args: nil_dynamic(),
    )
    |> widget.resolve(dispatch_result: _)

  result |> should.be_error
}

// ============================================================================
// dispatch_ui — set_system_prompt
// ============================================================================

pub fn set_system_prompt_via_ui_test() {
  let handle = system_prompt.create(text: "original")

  let assert Ok(args_dynamic) =
    json.object([#("text", json.string("updated prompt"))])
    |> json.to_string
    |> json.parse(decode.dynamic)

  let #(handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "set_system_prompt",
      args: args_dynamic,
    )

  result |> should.equal(Some(""))

  case widget.view_messages(handle) {
    [message.Request(parts: [message.SystemPart(text)])] ->
      text |> should.equal("updated prompt")
    _ -> should.fail()
  }
}

// ============================================================================
// dispatch_ui — reset_system_prompt
// ============================================================================

pub fn reset_system_prompt_via_ui_test() {
  let handle = system_prompt.create(text: "custom text")

  let #(handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "reset_system_prompt",
      args: nil_dynamic(),
    )

  result |> should.equal(Some(""))

  case widget.view_messages(handle) {
    [message.Request(parts: [message.SystemPart(text)])] ->
      string.contains(text, "Eddie") |> should.be_true
    _ -> should.fail()
  }
}

// ============================================================================
// dispatch_ui — unknown event
// ============================================================================

pub fn unknown_ui_event_returns_none_test() {
  let handle = system_prompt.create(text: "test")

  let #(_handle, result) =
    widget.dispatch_ui(
      handle: handle,
      event_name: "unknown_event",
      args: nil_dynamic(),
    )

  result |> should.equal(None)
}
