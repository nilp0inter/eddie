/// SystemPrompt widget — identity and framing text for the agent.
///
/// The simplest widget: holds a single text string used as the system prompt.
/// UI-only (no LLM tools). Editable from the browser via set/reset events.
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/set

import eddie/cmd.{type Cmd, CmdNone}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

// ============================================================================
// Model
// ============================================================================

pub type SystemPromptModel {
  SystemPromptModel(text: String)
}

// ============================================================================
// Messages
// ============================================================================

pub type SystemPromptMsg {
  SetSystemPrompt(text: String)
  ResetSystemPrompt
}

// ============================================================================
// Update
// ============================================================================

fn update(
  _model: SystemPromptModel,
  msg: SystemPromptMsg,
) -> #(SystemPromptModel, Cmd(SystemPromptMsg)) {
  case msg {
    SetSystemPrompt(text) -> #(SystemPromptModel(text: text), CmdNone)
    ResetSystemPrompt -> #(SystemPromptModel(text: default_text), CmdNone)
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: SystemPromptModel) -> List(Message) {
  [message.Request(parts: [message.SystemPart(model.text)])]
}

fn view_tools(_model: SystemPromptModel) -> List(ToolDefinition) {
  []
}

fn view_state(model: SystemPromptModel) -> List(ServerEvent) {
  [protocol.SystemPromptUpdated(text: model.text)]
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: SystemPromptModel,
  _tool_name: String,
  _args: Dynamic,
) -> Result(SystemPromptMsg, String) {
  Error("SystemPrompt has no LLM tools")
}

fn from_ui(
  _model: SystemPromptModel,
  event_name: String,
  args: Dynamic,
) -> Option(SystemPromptMsg) {
  case event_name {
    "set_system_prompt" -> {
      let text_decoder = decode.at(["text"], decode.string)
      case decode.run(args, text_decoder) {
        Ok(text) -> Some(SetSystemPrompt(text: text))
        Error(_) -> None
      }
    }
    "reset_system_prompt" -> Some(ResetSystemPrompt)
    _ -> None
  }
}

// ============================================================================
// Factory
// ============================================================================

/// Create a SystemPrompt widget handle with the given initial text.
pub fn create(text text: String) -> WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "system_prompt",
    model: SystemPromptModel(text: text),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_state: view_state,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.from_list(["set_system_prompt", "reset_system_prompt"]),
    protocol_free_tools: set.new(),
  ))
}

/// Create a SystemPrompt widget handle with the default text.
pub fn create_default() -> WidgetHandle {
  create(text: default_text)
}

// ============================================================================
// Default text
// ============================================================================

const default_text = "You are Eddie, an AI coding assistant. You help users by planning work into tasks, executing them one at a time, and recording what you learn as task memories.

When a task involves multiple independent steps that can run at the same time, spawn subagents to handle them in parallel. Use Tasks for work that must happen sequentially — one step finishing before the next begins."
