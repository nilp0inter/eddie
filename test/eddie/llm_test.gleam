import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

import eddie/llm
import eddie/message
import eddie/tool

// ============================================================================
// Tests: build_request
// ============================================================================

pub fn build_request_sets_method_and_path_test() {
  let config =
    llm.LlmConfig(
      api_base: "https://api.openai.com/v1",
      api_key: "test-key",
      model: "gpt-4o",
    )
  let messages = [
    message.Request(parts: [message.SystemPart("You are helpful.")]),
    message.Request(parts: [message.UserPart("Hello")]),
  ]

  let request = llm.build_request(config: config, messages: messages, tools: [])

  // Should be a POST to /chat/completions
  request.method |> should.equal(gleam_http_post())
  string.contains(request.path, "/chat/completions") |> should.be_true
}

pub fn build_request_includes_auth_header_test() {
  let config =
    llm.LlmConfig(
      api_base: "https://api.openai.com/v1",
      api_key: "sk-test-123",
      model: "gpt-4o",
    )
  let messages = [
    message.Request(parts: [message.UserPart("Hi")]),
  ]

  let request = llm.build_request(config: config, messages: messages, tools: [])

  // Should have Authorization header
  let auth_header = list.find(request.headers, fn(h) { h.0 == "authorization" })
  case auth_header {
    Ok(#(_, value)) -> string.contains(value, "sk-test-123")
    Error(Nil) -> False
  }
  |> should.be_true
}

pub fn build_request_body_contains_model_test() {
  let config =
    llm.LlmConfig(
      api_base: "https://api.openai.com/v1",
      api_key: "test-key",
      model: "gpt-4o-mini",
    )
  let messages = [
    message.Request(parts: [message.UserPart("Hi")]),
  ]

  let request = llm.build_request(config: config, messages: messages, tools: [])

  string.contains(request.body, "gpt-4o-mini") |> should.be_true
}

pub fn build_request_body_contains_messages_test() {
  let config =
    llm.LlmConfig(
      api_base: "https://api.openai.com/v1",
      api_key: "test-key",
      model: "gpt-4o",
    )
  let messages = [
    message.Request(parts: [message.SystemPart("Be helpful.")]),
    message.Request(parts: [message.UserPart("What is 2+2?")]),
  ]

  let request = llm.build_request(config: config, messages: messages, tools: [])

  string.contains(request.body, "Be helpful.") |> should.be_true
  string.contains(request.body, "What is 2+2?") |> should.be_true
}

pub fn build_request_includes_tools_when_provided_test() {
  let config =
    llm.LlmConfig(
      api_base: "https://api.openai.com/v1",
      api_key: "test-key",
      model: "gpt-4o",
    )
  let messages = [
    message.Request(parts: [message.UserPart("Hi")]),
  ]
  let schema =
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([])),
    ])
  let assert Ok(td) =
    tool.new(
      name: "get_weather",
      description: "Get the weather",
      parameters_json: schema,
    )

  let request =
    llm.build_request(config: config, messages: messages, tools: [td])

  string.contains(request.body, "get_weather") |> should.be_true
}

// ============================================================================
// Tests: parse_response
// ============================================================================

pub fn parse_response_text_only_test() {
  let json_body =
    "{\"id\":\"chatcmpl-123\",\"object\":\"chat.completion\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello! How can I help?\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}"
  let resp = response.new(200) |> response.set_body(json_body)

  let result = llm.parse_response(response: resp)

  case result {
    Ok(message.Response(parts: [message.TextPart(text)])) ->
      text == "Hello! How can I help?"
    _ -> False
  }
  |> should.be_true
}

pub fn parse_response_with_tool_call_test() {
  let json_body =
    "{\"id\":\"chatcmpl-456\",\"object\":\"chat.completion\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"create_task\",\"arguments\":\"{\\\"description\\\":\\\"Fix bug\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}"
  let resp = response.new(200) |> response.set_body(json_body)

  let result = llm.parse_response(response: resp)

  case result {
    Ok(message.Response(parts: [message.ToolCallPart(name, args_json, id)])) ->
      name == "create_task"
      && string.contains(args_json, "Fix bug")
      && id == "call_abc"
    _ -> False
  }
  |> should.be_true
}

pub fn parse_response_empty_choices_test() {
  let json_body =
    "{\"id\":\"chatcmpl-789\",\"object\":\"chat.completion\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":0,\"total_tokens\":10}}"
  let resp = response.new(200) |> response.set_body(json_body)

  let result = llm.parse_response(response: resp)
  result |> should.be_error
}

pub fn parse_response_api_error_test() {
  let json_body =
    "{\"error\":{\"message\":\"Rate limit exceeded\",\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}"
  let resp = response.new(429) |> response.set_body(json_body)

  let result = llm.parse_response(response: resp)
  result |> should.be_error
}

// ============================================================================
// Helpers
// ============================================================================

/// Get the HTTP Post method value.
fn gleam_http_post() -> http.Method {
  http.Post
}
