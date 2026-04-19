/// Structured output extraction — mini pydantic-ai for Eddie.
///
/// Two strategies for extracting typed data from LLM responses:
/// - **Tool-call**: Register a fake tool whose arguments ARE the schema.
///   LLM "calls" the tool; we validate the arguments with sextant.
/// - **Native**: Send the schema as `response_format` (json_schema).
///   LLM returns JSON text; we parse and validate with sextant.
///
/// Both strategies share a retry loop: on validation failure, we send
/// a structured error message back to the LLM and re-request.
///
/// This module is sans-IO — it builds glopenai requests and parses
/// responses, but does not perform HTTP. The caller provides a send
/// function.
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

import eddie/llm.{type LlmConfig}
import eddie/message.{type Message}
import glopenai/chat
import glopenai/config
import glopenai/shared
import sextant

/// A typed output schema for structured extraction.
/// Wraps a sextant schema with metadata for the LLM.
pub type OutputSchema(a) {
  OutputSchema(name: String, description: String, schema: sextant.JsonSchema(a))
}

/// The extraction strategy to use.
pub type Strategy {
  /// Register a fake tool; LLM "calls" it with structured args
  ToolCallStrategy
  /// Send schema as response_format; LLM returns JSON text
  NativeStrategy
}

/// Errors during structured output extraction.
pub type StructuredOutputError {
  /// HTTP send failed
  SendError(String)
  /// LLM API returned an unparseable response
  ApiError(String)
  /// LLM returned no choices
  EmptyResponse
  /// Exhausted all retries without valid output
  MaxRetriesExceeded(last_errors: List(String))
  /// LLM returned neither tool call nor text (unexpected)
  UnexpectedResponse(String)
}

/// Result of a single extraction attempt before retry logic.
type AttemptResult(a) {
  /// Successfully extracted and validated
  AttemptOk(a)
  /// Validation failed; include error messages for retry
  AttemptRetry(errors: List(String), tool_call_id: String, tool_name: String)
  /// Unrecoverable error
  AttemptFail(StructuredOutputError)
}

/// Extract structured output from the LLM.
///
/// Takes existing conversation messages, an output schema, a strategy,
/// and a max retry count. Returns the validated, typed result.
///
/// The send_fn is injected for testability (same pattern as agent.gleam).
pub fn extract(
  config config: LlmConfig,
  messages messages: List(Message),
  output output: OutputSchema(a),
  strategy strategy: Strategy,
  max_retries max_retries: Int,
  send_fn send_fn: fn(Request(String)) -> Result(Response(String), String),
) -> Result(a, StructuredOutputError) {
  extract_loop(
    config: config,
    messages: messages,
    output: output,
    strategy: strategy,
    max_retries: max_retries,
    send_fn: send_fn,
    attempt: 0,
    retry_messages: [],
  )
}

/// The recursive retry loop.
fn extract_loop(
  config config: LlmConfig,
  messages messages: List(Message),
  output output: OutputSchema(a),
  strategy strategy: Strategy,
  max_retries max_retries: Int,
  send_fn send_fn: fn(Request(String)) -> Result(Response(String), String),
  attempt attempt: Int,
  retry_messages retry_messages: List(Message),
) -> Result(a, StructuredOutputError) {
  // Build and send the request
  let request =
    build_extraction_request(
      config: config,
      messages: list.append(messages, retry_messages),
      output: output,
      strategy: strategy,
    )

  case send_fn(request) {
    Error(reason) -> Error(SendError(reason))
    Ok(response) -> {
      let attempt_result =
        parse_and_validate(
          response: response,
          output: output,
          strategy: strategy,
        )
      case attempt_result {
        AttemptOk(value) -> Ok(value)
        AttemptFail(err) -> Error(err)
        AttemptRetry(errors, tool_call_id, tool_name) ->
          handle_retry(
            config: config,
            messages: messages,
            output: output,
            strategy: strategy,
            max_retries: max_retries,
            send_fn: send_fn,
            attempt: attempt,
            errors: errors,
            tool_call_id: tool_call_id,
            tool_name: tool_name,
          )
      }
    }
  }
}

/// Handle a retry: check if we have retries left, build error feedback,
/// and recurse.
fn handle_retry(
  config config: LlmConfig,
  messages messages: List(Message),
  output output: OutputSchema(a),
  strategy strategy: Strategy,
  max_retries max_retries: Int,
  send_fn send_fn: fn(Request(String)) -> Result(Response(String), String),
  attempt attempt: Int,
  errors errors: List(String),
  tool_call_id tool_call_id: String,
  tool_name tool_name: String,
) -> Result(a, StructuredOutputError) {
  use <- bool.guard(
    when: attempt >= max_retries,
    return: Error(MaxRetriesExceeded(last_errors: errors)),
  )
  // Build retry messages: the failed response + error feedback
  let retry_messages =
    build_retry_messages(
      errors: errors,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      strategy: strategy,
    )
  extract_loop(
    config: config,
    messages: messages,
    output: output,
    strategy: strategy,
    max_retries: max_retries,
    send_fn: send_fn,
    attempt: attempt + 1,
    retry_messages: retry_messages,
  )
}

// ============================================================================
// Request building
// ============================================================================

/// Build the LLM request for structured extraction.
fn build_extraction_request(
  config config: LlmConfig,
  messages messages: List(Message),
  output output: OutputSchema(a),
  strategy strategy: Strategy,
) -> Request(String) {
  let glopenai_config =
    config.new(config.api_key)
    |> config.with_api_base(config.api_base)

  let chat_messages = message.to_chat_messages(messages)

  let params = chat.new_create_request(config.model, chat_messages)

  case strategy {
    ToolCallStrategy -> {
      let tool = build_output_tool(output: output)
      chat.with_tools(params, [tool])
      |> chat.create_request(glopenai_config, _)
    }
    NativeStrategy -> {
      let format = build_response_format(output: output)
      chat.with_response_format(params, format)
      |> chat.create_request(glopenai_config, _)
    }
  }
}

/// Build a fake tool definition for the tool-call strategy.
fn build_output_tool(output output: OutputSchema(a)) -> chat.ChatCompletionTool {
  let schema_json = sextant.to_json(output.schema)
  // Strip the $schema key — tool parameters don't include it
  let parameters_json = strip_dollar_schema(schema_json)
  let parameters_dynamic = json_to_dynamic(json.to_string(parameters_json))

  chat.FunctionTool(function: shared.FunctionObject(
    name: output.name,
    description: Some(output.description),
    parameters: Some(parameters_dynamic),
    strict: Some(True),
  ))
}

/// Build the response_format for the native strategy.
fn build_response_format(
  output output: OutputSchema(a),
) -> shared.ResponseFormat {
  let schema_json = sextant.to_json(output.schema)
  let schema_dynamic = json_to_dynamic(json.to_string(schema_json))

  shared.ResponseFormatJsonSchemaVariant(
    json_schema: shared.ResponseFormatJsonSchema(
      name: output.name,
      description: Some(output.description),
      schema: Some(schema_dynamic),
      strict: Some(True),
    ),
  )
}

// ============================================================================
// Response parsing and validation
// ============================================================================

/// Parse the HTTP response and validate against the schema.
fn parse_and_validate(
  response response: Response(String),
  output output: OutputSchema(a),
  strategy strategy: Strategy,
) -> AttemptResult(a) {
  case chat.create_response(response) {
    Error(_glopenai_error) ->
      AttemptFail(ApiError("Failed to parse LLM response"))
    Ok(completion) ->
      case completion.choices {
        [] -> AttemptFail(EmptyResponse)
        [choice, ..] ->
          validate_choice(
            message: choice.message,
            output: output,
            strategy: strategy,
          )
      }
  }
}

/// Validate a response choice based on the strategy.
fn validate_choice(
  message message: chat.ChatCompletionResponseMessage,
  output output: OutputSchema(a),
  strategy strategy: Strategy,
) -> AttemptResult(a) {
  case strategy {
    ToolCallStrategy -> validate_tool_call(message: message, output: output)
    NativeStrategy -> validate_native(message: message, output: output)
  }
}

/// Validate a tool-call response: find the matching tool call,
/// parse its arguments JSON, and validate with sextant.
fn validate_tool_call(
  message message: chat.ChatCompletionResponseMessage,
  output output: OutputSchema(a),
) -> AttemptResult(a) {
  case message.tool_calls {
    Some([call, ..]) -> {
      let chat.FunctionToolCall(id, function) = call
      let json_string = strip_markdown_fences(function.arguments)
      validate_json_string(
        json_string: json_string,
        output: output,
        tool_call_id: id,
        tool_name: function.name,
      )
    }
    _ ->
      AttemptFail(UnexpectedResponse(
        "Tool-call strategy: LLM did not return a tool call",
      ))
  }
}

/// Validate a native response: parse the text content as JSON
/// and validate with sextant.
fn validate_native(
  message message: chat.ChatCompletionResponseMessage,
  output output: OutputSchema(a),
) -> AttemptResult(a) {
  case message.content {
    Some(text) -> {
      let json_string = strip_markdown_fences(text)
      validate_json_string(
        json_string: json_string,
        output: output,
        // Native strategy uses empty tool_call_id; retry sends as user message
        tool_call_id: "",
        tool_name: output.name,
      )
    }
    None ->
      AttemptFail(UnexpectedResponse(
        "Native strategy: LLM returned no text content",
      ))
  }
}

/// Parse a JSON string and validate against the sextant schema.
fn validate_json_string(
  json_string json_string: String,
  output output: OutputSchema(a),
  tool_call_id tool_call_id: String,
  tool_name tool_name: String,
) -> AttemptResult(a) {
  case json.parse(json_string, decode.dynamic) {
    Error(_json_error) ->
      AttemptRetry(
        errors: ["Invalid JSON: " <> json_string],
        tool_call_id: tool_call_id,
        tool_name: tool_name,
      )
    Ok(dynamic_value) ->
      case sextant.run(dynamic_value, output.schema) {
        Ok(value) -> AttemptOk(value)
        Error(validation_errors) -> {
          let error_strings =
            list.map(validation_errors, sextant.error_to_string)
          AttemptRetry(
            errors: error_strings,
            tool_call_id: tool_call_id,
            tool_name: tool_name,
          )
        }
      }
  }
}

// ============================================================================
// Retry message construction
// ============================================================================

/// Build the retry messages to send back to the LLM.
/// For tool-call strategy: include the failed tool call + retry feedback.
/// For native strategy: include user message with error details.
fn build_retry_messages(
  errors errors: List(String),
  tool_call_id tool_call_id: String,
  tool_name tool_name: String,
  strategy strategy: Strategy,
) -> List(Message) {
  let error_text =
    "Validation failed. Please fix these errors and try again:\n"
    <> string.join(errors, "\n")

  case strategy {
    ToolCallStrategy -> [
      // Echo back the tool call so the conversation stays well-formed
      message.Response(parts: [
        message.ToolCallPart(
          tool_name: tool_name,
          arguments_json: "{}",
          tool_call_id: tool_call_id,
        ),
      ]),
      // Send retry feedback as a tool return
      message.Request(parts: [
        message.RetryPart(
          tool_name: tool_name,
          content: error_text,
          tool_call_id: tool_call_id,
        ),
      ]),
    ]
    NativeStrategy -> [
      message.Request(parts: [message.UserPart(content: error_text)]),
    ]
  }
}

// ============================================================================
// Utility helpers
// ============================================================================

/// Strip markdown code fences that LLMs sometimes wrap around JSON.
/// Handles ```json ... ``` and ``` ... ``` patterns.
pub fn strip_markdown_fences(input: String) -> String {
  let trimmed = string.trim(input)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      // Remove opening fence (```json or ```)
      let without_open = case string.split_once(trimmed, "\n") {
        Ok(#(_, rest)) -> rest
        Error(Nil) -> trimmed
      }
      // Remove closing fence
      case string.ends_with(without_open, "```") {
        True ->
          string.drop_end(without_open, 3)
          |> string.trim
        False -> string.trim(without_open)
      }
    }
  }
}

/// Strip the $schema key from a JSON schema object.
/// Tool parameters and response_format schemas don't include it.
/// Re-serialises via the FFI dynamic_to_json encoder.
fn strip_dollar_schema(schema_json: json.Json) -> json.Json {
  let json_string = json.to_string(schema_json)
  case json.parse(json_string, decode.dict(decode.string, decode.dynamic)) {
    Error(_decode_error) -> schema_json
    Ok(entries) -> {
      let filtered =
        entries
        |> dict.to_list
        |> list.filter(fn(pair) { pair.0 != "$schema" })
        |> list.map(fn(pair) { #(pair.0, encode_dynamic(pair.1)) })
      json.object(filtered)
    }
  }
}

/// Parse a JSON string to a Dynamic value.
fn json_to_dynamic(json_string: String) -> Dynamic {
  let identity_decoder =
    decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })
  json.parse(json_string, identity_decoder)
  |> result.unwrap(dynamic.string(json_string))
}

/// Encode a Dynamic value back to json.Json using Erlang FFI.
/// This is the same approach glopenai uses (codec.dynamic_to_json).
@external(erlang, "eddie_ffi", "dynamic_to_json")
fn encode_dynamic(value: Dynamic) -> json.Json
