/// Token Usage widget — displays input/output tokens per request.
///
/// Display-only: no LLM tools or messages. Receives UsageRecorded
/// via widget.send() after each LLM response.
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/set
import gleam/string
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd.{type Cmd, CmdNone}
import eddie/message.{type Message}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}

// ============================================================================
// Model
// ============================================================================

pub type TokenRecord {
  TokenRecord(request_number: Int, input_tokens: Int, output_tokens: Int)
}

pub type TokenUsageModel {
  TokenUsageModel(records: List(TokenRecord))
}

// ============================================================================
// Messages
// ============================================================================

pub type TokenUsageMsg {
  UsageRecorded(input_tokens: Int, output_tokens: Int)
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: TokenUsageModel,
  msg: TokenUsageMsg,
) -> #(TokenUsageModel, Cmd(TokenUsageMsg)) {
  let UsageRecorded(input_tokens, output_tokens) = msg
  let request_number = list.length(model.records) + 1
  let record =
    TokenRecord(
      request_number: request_number,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
    )
  // Prepend for efficiency, reverse in view
  #(TokenUsageModel(records: [record, ..model.records]), CmdNone)
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(_model: TokenUsageModel) -> List(Message) {
  []
}

fn view_tools(_model: TokenUsageModel) -> List(ToolDefinition) {
  []
}

fn view_html(model: TokenUsageModel) -> Element(Nil) {
  case model.records {
    [] ->
      html.div([], [
        html.h3([], [html.text("Token Usage")]),
        html.em([], [html.text("No requests yet")]),
      ])
    _ -> {
      let records = list.reverse(model.records)
      let total_input =
        list.fold(records, 0, fn(acc, r: TokenRecord) { acc + r.input_tokens })
      let total_output =
        list.fold(records, 0, fn(acc, r: TokenRecord) { acc + r.output_tokens })
      let request_count = list.length(records)

      let summary =
        int.to_string(request_count)
        <> " requests | in: "
        <> format_tokens(total_input)
        <> " | out: "
        <> format_tokens(total_output)

      // Show last 10 records
      let visible = list.drop(records, int.max(0, request_count - 10))
      let record_lines =
        list.map(visible, fn(r: TokenRecord) {
          html.div([], [
            html.text(
              "#"
              <> int.to_string(r.request_number)
              <> ": in="
              <> format_tokens(r.input_tokens)
              <> " out="
              <> format_tokens(r.output_tokens),
            ),
          ])
        })

      html.div([], [
        html.h3([], [html.text("Token Usage")]),
        html.div([], [html.text(summary)]),
        html.div([], record_lines),
      ])
    }
  }
}

/// Format token count with K/M suffix.
fn format_tokens(count: Int) -> String {
  case count >= 1_000_000 {
    True -> format_with_decimal(count / 100_000, "M")
    False ->
      case count >= 1000 {
        True -> format_with_decimal(count / 100, "K")
        False -> int.to_string(count)
      }
  }
}

/// Insert a decimal point before the last digit: "12" -> "1.2", "1" -> "0.1"
fn format_with_decimal(value: Int, suffix: String) -> String {
  let digits = int.to_string(value)
  let len = string.length(digits)
  case len {
    1 -> "0." <> digits <> suffix
    _ -> {
      let before = string.slice(digits, 0, len - 1)
      let after = string.slice(digits, len - 1, 1)
      before <> "." <> after <> suffix
    }
  }
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: TokenUsageModel,
  _tool_name: String,
  _args: Dynamic,
) -> Result(TokenUsageMsg, String) {
  Error("TokenUsage has no LLM tools")
}

fn from_ui(
  _model: TokenUsageModel,
  _event_name: String,
  _args: Dynamic,
) -> Option(TokenUsageMsg) {
  None
}

// ============================================================================
// Factory
// ============================================================================

/// Create a Token Usage widget handle with empty state.
pub fn create() -> WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "token_usage",
    model: TokenUsageModel(records: []),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_html: view_html,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.new(),
    protocol_free_tools: set.new(),
  ))
}
