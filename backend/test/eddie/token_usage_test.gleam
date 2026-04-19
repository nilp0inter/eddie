import gleam/dynamic
import gleam/list
import gleam/option.{None}
import gleeunit/should

import eddie/coerce
import eddie/widget

import eddie/widgets/token_usage
import eddie_shared/protocol

// ============================================================================
// Factory tests
// ============================================================================

pub fn create_empty_test() {
  let handle = token_usage.create()
  widget.id(handle)
  |> should.equal("token_usage")
}

pub fn empty_view_messages_test() {
  let handle = token_usage.create()
  widget.view_messages(handle)
  |> should.equal([])
}

pub fn empty_view_tools_test() {
  let handle = token_usage.create()
  widget.view_tools(handle)
  |> should.equal([])
}

pub fn empty_view_state_test() {
  let handle = token_usage.create()
  widget.view_state(handle)
  |> should.equal([])
}

// ============================================================================
// Send UsageRecorded tests
// ============================================================================

pub fn record_single_usage_test() {
  let handle = token_usage.create()
  let msg = token_usage.UsageRecorded(input_tokens: 100, output_tokens: 50)
  let assert Ok(updated) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))

  let events = widget.view_state(updated)
  events
  |> should.equal([protocol.TokensUsed(input: 100, output: 50)])
}

pub fn record_multiple_usage_test() {
  let handle = token_usage.create()
  let msg1 = token_usage.UsageRecorded(input_tokens: 100, output_tokens: 50)
  let assert Ok(h1) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg1))
  let msg2 = token_usage.UsageRecorded(input_tokens: 200, output_tokens: 75)
  let assert Ok(h2) = widget.send(handle: h1, msg: coerce.unsafe_coerce(msg2))

  let events = widget.view_state(h2)
  list.length(events)
  |> should.equal(2)
}

pub fn record_large_token_count_test() {
  let handle = token_usage.create()
  let msg =
    token_usage.UsageRecorded(input_tokens: 15_000, output_tokens: 2_500_000)
  let assert Ok(updated) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))

  let events = widget.view_state(updated)
  events
  |> should.equal([protocol.TokensUsed(input: 15_000, output: 2_500_000)])
}

// ============================================================================
// No LLM/UI interaction
// ============================================================================

pub fn from_llm_always_errors_test() {
  let handle = token_usage.create()
  let args = dynamic.string("test")
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "anything", args: args)
  result
  |> should.equal(Error("TokenUsage has no LLM tools"))
}

pub fn from_ui_always_none_test() {
  let handle = token_usage.create()
  let args = dynamic.string("test")
  let #(_updated, result) =
    widget.dispatch_ui(handle: handle, event_name: "anything", args: args)
  result
  |> should.equal(None)
}

// ============================================================================
// Request numbering
// ============================================================================

pub fn request_numbers_sequential_test() {
  let handle = token_usage.create()
  let msg1 = token_usage.UsageRecorded(input_tokens: 10, output_tokens: 5)
  let assert Ok(h1) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg1))
  let msg2 = token_usage.UsageRecorded(input_tokens: 20, output_tokens: 10)
  let assert Ok(h2) = widget.send(handle: h1, msg: coerce.unsafe_coerce(msg2))
  let msg3 = token_usage.UsageRecorded(input_tokens: 30, output_tokens: 15)
  let assert Ok(h3) = widget.send(handle: h2, msg: coerce.unsafe_coerce(msg3))

  let events = widget.view_state(h3)
  list.length(events)
  |> should.equal(3)
}
