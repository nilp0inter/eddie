/// Eddie's message types — the conversation building blocks.
///
/// Widgets produce and consume these types. The backend's LLM client
/// handles conversion to/from the wire format (glopenai).
import gleam/json

/// A single piece of content within a message.
pub type MessagePart {
  /// System-level instruction (only in requests)
  SystemPart(content: String)
  /// User-provided text (only in requests)
  UserPart(content: String)
  /// Model-generated text (only in responses)
  TextPart(content: String)
  /// Model requesting a tool call (only in responses)
  ToolCallPart(tool_name: String, arguments_json: String, tool_call_id: String)
  /// Result of a tool call sent back to the model (only in requests)
  ToolReturnPart(tool_name: String, content: String, tool_call_id: String)
  /// Retry prompt sent to the model after a validation failure
  RetryPart(tool_name: String, content: String, tool_call_id: String)
}

/// A message in the conversation history.
pub type Message {
  /// A message going to the model (system prompt, user text, tool returns)
  Request(parts: List(MessagePart))
  /// A message from the model (text, tool calls)
  Response(parts: List(MessagePart))
}

// ============================================================================
// JSON encoding
// ============================================================================

pub fn message_part_to_json(part: MessagePart) -> json.Json {
  case part {
    SystemPart(content) ->
      json.object([
        #("type", json.string("system")),
        #("content", json.string(content)),
      ])
    UserPart(content) ->
      json.object([
        #("type", json.string("user")),
        #("content", json.string(content)),
      ])
    TextPart(content) ->
      json.object([
        #("type", json.string("text")),
        #("content", json.string(content)),
      ])
    ToolCallPart(tool_name, arguments_json, tool_call_id) ->
      json.object([
        #("type", json.string("tool_call")),
        #("tool_name", json.string(tool_name)),
        #("arguments_json", json.string(arguments_json)),
        #("tool_call_id", json.string(tool_call_id)),
      ])
    ToolReturnPart(tool_name, content, tool_call_id) ->
      json.object([
        #("type", json.string("tool_return")),
        #("tool_name", json.string(tool_name)),
        #("content", json.string(content)),
        #("tool_call_id", json.string(tool_call_id)),
      ])
    RetryPart(tool_name, content, tool_call_id) ->
      json.object([
        #("type", json.string("retry")),
        #("tool_name", json.string(tool_name)),
        #("content", json.string(content)),
        #("tool_call_id", json.string(tool_call_id)),
      ])
  }
}

pub fn message_to_json(message: Message) -> json.Json {
  case message {
    Request(parts) ->
      json.object([
        #("role", json.string("request")),
        #("parts", json.array(parts, message_part_to_json)),
      ])
    Response(parts) ->
      json.object([
        #("role", json.string("response")),
        #("parts", json.array(parts, message_part_to_json)),
      ])
  }
}
