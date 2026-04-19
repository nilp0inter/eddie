/// Eddie's message types — the conversation building blocks.
///
/// Widgets produce and consume these types. The backend's LLM client
/// handles conversion to/from the wire format (glopenai).

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
