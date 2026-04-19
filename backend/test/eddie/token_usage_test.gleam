import gleam/dynamic
import gleam/option.{None}
import gleam/string
import gleeunit/should
import lustre/element

import eddie/coerce
import eddie/widget

import eddie/widgets/token_usage

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

pub fn empty_view_html_test() {
  let handle = token_usage.create()
  let html = element.to_string(widget.view_html(handle))
  string.contains(html, "No requests yet")
  |> should.be_true
}

// ============================================================================
// Send UsageRecorded tests
// ============================================================================

pub fn record_single_usage_test() {
  let handle = token_usage.create()
  let msg = token_usage.UsageRecorded(input_tokens: 100, output_tokens: 50)
  let assert Ok(updated) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))

  let html = element.to_string(widget.view_html(updated))
  string.contains(html, "1 requests")
  |> should.be_true
  string.contains(html, "in: 100")
  |> should.be_true
  string.contains(html, "out: 50")
  |> should.be_true
}

pub fn record_multiple_usage_test() {
  let handle = token_usage.create()
  let msg1 = token_usage.UsageRecorded(input_tokens: 100, output_tokens: 50)
  let assert Ok(h1) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg1))
  let msg2 = token_usage.UsageRecorded(input_tokens: 200, output_tokens: 75)
  let assert Ok(h2) = widget.send(handle: h1, msg: coerce.unsafe_coerce(msg2))

  let html = element.to_string(widget.view_html(h2))
  string.contains(html, "2 requests")
  |> should.be_true
  // Total input: 300, output: 125
  string.contains(html, "in: 300")
  |> should.be_true
  string.contains(html, "out: 125")
  |> should.be_true
}

pub fn record_large_token_count_test() {
  let handle = token_usage.create()
  let msg =
    token_usage.UsageRecorded(input_tokens: 15_000, output_tokens: 2_500_000)
  let assert Ok(updated) =
    widget.send(handle: handle, msg: coerce.unsafe_coerce(msg))

  let html = element.to_string(widget.view_html(updated))
  // 15000 should display as "15.0K"
  string.contains(html, "15.0K")
  |> should.be_true
  // 2500000 should display as "2.5M"
  string.contains(html, "2.5M")
  |> should.be_true
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

  let html = element.to_string(widget.view_html(h3))
  string.contains(html, "#1:")
  |> should.be_true
  string.contains(html, "#2:")
  |> should.be_true
  string.contains(html, "#3:")
  |> should.be_true
}
