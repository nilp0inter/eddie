/// LLM client bridge — sans-IO layer between Eddie and glopenai.
///
/// Builds glopenai requests from Eddie types and parses glopenai responses
/// back into Eddie types. Does not perform any HTTP — that's the caller's job.
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}

import eddie/message.{type Message}
import eddie/tool.{type ToolDefinition}
import glopenai/chat
import glopenai/config
import glopenai/error

/// Configuration for the LLM client.
pub type LlmConfig {
  LlmConfig(api_base: String, api_key: String, model: String)
}

/// Errors that can occur when parsing an LLM response.
pub type LlmError {
  /// glopenai could not parse the API response
  ApiError(error.GlopenaiError)
  /// The response contained no choices
  EmptyResponse
}

/// Build an HTTP request for a chat completion.
/// Takes Eddie messages and tools, converts them to glopenai types,
/// and produces a ready-to-send HTTP request.
pub fn build_request(
  config config: LlmConfig,
  messages messages: List(Message),
  tools tools: List(ToolDefinition),
) -> Request(String) {
  let glopenai_config =
    config.new(config.api_key)
    |> config.with_api_base(config.api_base)

  let chat_messages = message.to_chat_messages(messages)
  let chat_tools = list.map(tools, tool.to_chat_tool)

  let params = chat.new_create_request(config.model, chat_messages)

  let params = case chat_tools {
    [] -> params
    _ -> chat.with_tools(params, chat_tools)
  }

  chat.create_request(glopenai_config, params)
}

/// Parse an HTTP response into an Eddie Message.
/// Handles the glopenai response parsing and extracts the first choice.
pub fn parse_response(
  response response: Response(String),
) -> Result(Message, LlmError) {
  case chat.create_response(response) {
    Error(err) -> Error(ApiError(err))
    Ok(completion) ->
      case completion.choices {
        [choice, ..] -> Ok(response_message_to_eddie(choice.message))
        [] -> Error(EmptyResponse)
      }
  }
}

/// Convert a glopenai response message to an Eddie Response Message.
fn response_message_to_eddie(msg: chat.ChatCompletionResponseMessage) -> Message {
  let text_parts = case msg.content {
    Some(text) -> [message.TextPart(text)]
    None -> []
  }

  let tool_call_parts = case msg.tool_calls {
    Some(calls) ->
      list.map(calls, fn(call) {
        let chat.FunctionToolCall(id, function) = call
        message.ToolCallPart(
          tool_name: function.name,
          arguments_json: function.arguments,
          tool_call_id: id,
        )
      })
    None -> []
  }

  message.Response(parts: list.append(text_parts, tool_call_parts))
}
