/// Token Usage widget — displays input/output tokens per request.
///
/// Display-only: no LLM tools or messages. Receives UsageRecorded
/// via widget.send() after each LLM response.
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None}
import gleam/set

import eddie/cmd.{type Cmd, CmdNone}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

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

fn view_state(model: TokenUsageModel) -> List(ServerEvent) {
  list.map(list.reverse(model.records), fn(record) {
    protocol.TokensUsed(
      input: record.input_tokens,
      output: record.output_tokens,
    )
  })
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
    view_state: view_state,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.new(),
    protocol_free_tools: set.new(),
  ))
}
