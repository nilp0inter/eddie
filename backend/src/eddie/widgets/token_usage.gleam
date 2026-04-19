/// Token Usage widget — displays input/output tokens per request.
///
/// Display-only: no LLM tools or messages. Receives UsageRecorded
/// via widget.send() after each LLM response.
import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/set
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd.{type Cmd, CmdNone}
import eddie_shared/message.{type Message}
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

const max_visible = 20

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

      let visible = list.drop(records, int.max(0, request_count - max_visible))
      let chart = render_svg_chart(visible)

      let legend =
        html.div(
          [
            attribute.style("font-size", "11px"),
            attribute.style("display", "flex"),
            attribute.style("gap", "12px"),
            attribute.style("margin-top", "4px"),
          ],
          [
            html.span([], [html.text("\u{25a0} Input")]),
            html.span([], [html.text("\u{25a0} Output")]),
          ],
        )

      html.div([], [
        html.h3([], [html.text("Token Usage")]),
        html.div(
          [
            attribute.style("font-size", "12px"),
            attribute.style("color", "#a6adc8"),
          ],
          [html.text(summary)],
        ),
        chart,
        legend,
      ])
    }
  }
}

fn render_svg_chart(records: List(TokenRecord)) -> Element(Nil) {
  let count = list.length(records)
  let bar_width = 12
  let gap = 3
  let svg_width = count * { bar_width + gap }
  let chart_height = 100

  // Find max total tokens for scaling
  let max_tokens =
    list.fold(records, 1, fn(acc, r: TokenRecord) {
      int.max(acc, r.input_tokens + r.output_tokens)
    })

  let bars =
    list.index_map(records, fn(record, index) {
      let bar_x = index * { bar_width + gap }
      let total = record.input_tokens + record.output_tokens
      let total_height =
        float.round(
          int.to_float(total)
          *. int.to_float(chart_height)
          /. int.to_float(max_tokens),
        )
      let input_height =
        float.round(
          int.to_float(record.input_tokens)
          *. int.to_float(chart_height)
          /. int.to_float(max_tokens),
        )
      let output_height = total_height - input_height

      let tooltip =
        "#"
        <> int.to_string(record.request_number)
        <> ": in="
        <> format_tokens(record.input_tokens)
        <> " out="
        <> format_tokens(record.output_tokens)

      // Input bar (blue) on bottom, output bar (orange) on top
      let input_y = chart_height - input_height
      let output_y = input_y - output_height

      [
        // Output bar (orange, on top)
        element.element(
          "rect",
          [
            attribute.attribute("x", int.to_string(bar_x)),
            attribute.attribute("y", int.to_string(output_y)),
            attribute.attribute("width", int.to_string(bar_width)),
            attribute.attribute("height", int.to_string(output_height)),
            attribute.attribute("fill", "#ed7d31"),
            attribute.attribute("rx", "1"),
          ],
          [element.element("title", [], [html.text(tooltip)])],
        ),
        // Input bar (blue, on bottom)
        element.element(
          "rect",
          [
            attribute.attribute("x", int.to_string(bar_x)),
            attribute.attribute("y", int.to_string(input_y)),
            attribute.attribute("width", int.to_string(bar_width)),
            attribute.attribute("height", int.to_string(input_height)),
            attribute.attribute("fill", "#5b9bd5"),
            attribute.attribute("rx", "1"),
          ],
          [element.element("title", [], [html.text(tooltip)])],
        ),
      ]
    })

  element.element(
    "svg",
    [
      attribute.attribute("width", int.to_string(svg_width)),
      attribute.attribute("height", int.to_string(chart_height)),
      attribute.attribute(
        "viewBox",
        "0 0 " <> int.to_string(svg_width) <> " " <> int.to_string(chart_height),
      ),
      attribute.style("display", "block"),
      attribute.style("margin", "8px 0"),
    ],
    list.flatten(bars),
  )
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
