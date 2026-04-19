/// Backend-specific message conversions — glopenai wire format.
///
/// The canonical message types (MessagePart, Message) live in
/// eddie_shared/message. This module provides conversion to/from
/// glopenai's ChatMessage for the LLM client layer.
import gleam/list
import gleam/option.{None, Some}
import glopenai/chat
import glopenai/shared

import eddie_shared/message.{
  type Message, type MessagePart, Request, Response, RetryPart, SystemPart,
  TextPart, ToolCallPart, ToolReturnPart, UserPart,
}

// ============================================================================
// Conversion to glopenai types
// ============================================================================

/// Convert a single MessagePart to a glopenai ChatMessage.
fn part_to_chat_message(part: MessagePart) -> chat.ChatMessage {
  case part {
    SystemPart(content) -> chat.system_message(content)
    UserPart(content) -> chat.user_message(content)
    TextPart(content) -> chat.assistant_message(content)
    ToolCallPart(tool_name, arguments_json, tool_call_id) ->
      chat.AssistantMessage(
        content: None,
        refusal: None,
        name: None,
        tool_calls: Some([
          chat.FunctionToolCall(
            id: tool_call_id,
            function: shared.FunctionCall(
              name: tool_name,
              arguments: arguments_json,
            ),
          ),
        ]),
      )
    ToolReturnPart(_tool_name, content, tool_call_id) ->
      chat.tool_message(content, tool_call_id)
    RetryPart(_tool_name, content, tool_call_id) ->
      chat.tool_message(content, tool_call_id)
  }
}

/// Convert a list of Messages to a flat list of ChatMessages.
pub fn to_chat_messages(messages: List(Message)) -> List(chat.ChatMessage) {
  list.flat_map(messages, fn(message) {
    case message {
      Request(parts) -> list.map(parts, part_to_chat_message)
      Response(parts) -> response_parts_to_chat_messages(parts)
    }
  })
}

/// Convert a ToolCallPart to a glopenai FunctionToolCall.
fn tool_call_part_to_function_tool_call(part: MessagePart) -> chat.ToolCall {
  case part {
    ToolCallPart(tool_name, arguments_json, tool_call_id) ->
      chat.FunctionToolCall(
        id: tool_call_id,
        function: shared.FunctionCall(
          name: tool_name,
          arguments: arguments_json,
        ),
      )
    // Unreachable — only called on partitioned ToolCallParts
    _ ->
      chat.FunctionToolCall(
        id: "",
        function: shared.FunctionCall(name: "", arguments: ""),
      )
  }
}

/// Response parts need special handling: consecutive tool calls should be
/// grouped into a single AssistantMessage, and text parts can coexist.
fn response_parts_to_chat_messages(
  parts: List(MessagePart),
) -> List(chat.ChatMessage) {
  let #(tool_calls, other_parts) =
    list.partition(parts, fn(part) {
      case part {
        ToolCallPart(_, _, _) -> True
        _ -> False
      }
    })

  let other_messages = list.map(other_parts, part_to_chat_message)

  case tool_calls {
    [] -> other_messages
    _ -> {
      let calls = list.map(tool_calls, tool_call_part_to_function_tool_call)

      // Find any text content from the response to include in the
      // assistant message alongside tool calls
      let text_content = case other_parts {
        [TextPart(content), ..] -> Some(chat.AssistantTextContent(content))
        _ -> None
      }

      let assistant_msg =
        chat.AssistantMessage(
          content: text_content,
          refusal: None,
          name: None,
          tool_calls: Some(calls),
        )

      // If we used the text in the assistant message, skip it from others
      let remaining = case text_content {
        Some(_) -> list.drop(other_messages, 1)
        None -> other_messages
      }

      [assistant_msg, ..remaining]
    }
  }
}

// ============================================================================
// Conversion from glopenai response
// ============================================================================

/// Parse a glopenai CreateChatCompletionResponse into an Eddie Message.
/// Takes the first choice (standard for non-n>1 requests).
pub fn from_chat_response(
  response: chat.CreateChatCompletionResponse,
) -> Result(Message, Nil) {
  case response.choices {
    [choice, ..] -> Ok(response_message_to_message(choice.message))
    [] -> Error(Nil)
  }
}

/// Convert a glopenai response message to an Eddie Response Message.
fn response_message_to_message(
  msg: chat.ChatCompletionResponseMessage,
) -> Message {
  let text_parts = case msg.content {
    Some(text) -> [TextPart(text)]
    None -> []
  }

  let tool_call_parts = case msg.tool_calls {
    Some(calls) ->
      list.map(calls, fn(call) {
        let chat.FunctionToolCall(id, function) = call
        ToolCallPart(
          tool_name: function.name,
          arguments_json: function.arguments,
          tool_call_id: id,
        )
      })
    None -> []
  }

  Response(parts: list.append(text_parts, tool_call_parts))
}
