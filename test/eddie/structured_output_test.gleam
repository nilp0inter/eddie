import gleam/http/response
import gleam/string
import gleeunit/should

import eddie/llm
import eddie/message
import eddie/structured_output.{
  type OutputSchema, NativeStrategy, OutputSchema, ToolCallStrategy,
}
import sextant

// ============================================================================
// Test schema: a simple User with name and age
// ============================================================================

pub type User {
  User(name: String, age: Int)
}

fn user_schema() -> OutputSchema(User) {
  let schema = {
    use name <- sextant.field("name", sextant.string())
    use age <- sextant.field("age", sextant.integer())
    sextant.success(User(name:, age:))
  }
  OutputSchema(name: "user", description: "Extract user info", schema: schema)
}

fn test_config() -> llm.LlmConfig {
  llm.LlmConfig(
    api_base: "https://test.example.com/v1",
    api_key: "test-key",
    model: "test-model",
  )
}

// ============================================================================
// Mock response builders
// ============================================================================

fn text_response_json(text: String) -> String {
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\""
  <> escape_json(text)
  <> "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}

fn tool_call_response_json(
  tool_name tool_name: String,
  args_json args_json: String,
  call_id call_id: String,
) -> String {
  "{\"id\":\"chatcmpl-2\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\""
  <> call_id
  <> "\",\"type\":\"function\",\"function\":{\"name\":\""
  <> tool_name
  <> "\",\"arguments\":\""
  <> escape_json(args_json)
  <> "\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

fn mock_response(body: String) -> response.Response(String) {
  response.new(200) |> response.set_body(body)
}

/// Create a simple mock send function that returns responses in sequence.
/// Uses a mutable index via process dictionary (Erlang-specific).
fn mock_send_sequence(
  responses responses: List(String),
) -> fn(a) -> Result(response.Response(String), String) {
  let state = create_counter()
  fn(_request) {
    let index = increment_counter(state)
    case list_at(responses, index) {
      Ok(body) -> Ok(mock_response(body))
      Error(Nil) -> Error("No more mock responses")
    }
  }
}

/// Get element at index from a list.
fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [first, ..], 0 -> Ok(first)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

// Erlang process dictionary counter for sequencing mock responses
@external(erlang, "eddie_test_ffi", "create_counter")
fn create_counter() -> a

@external(erlang, "eddie_test_ffi", "increment_counter")
fn increment_counter(counter: a) -> Int

// ============================================================================
// Tests: Tool-call strategy — successful extraction
// ============================================================================

pub fn tool_call_extract_valid_test() {
  let output = user_schema()
  let args = "{\"name\":\"Alice\",\"age\":30}"
  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: args,
      call_id: "call_1",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 3,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Alice")
  user.age |> should.equal(30)
}

// ============================================================================
// Tests: Native strategy — successful extraction
// ============================================================================

pub fn native_extract_valid_test() {
  let output = user_schema()
  let json_text = "{\"name\":\"Bob\",\"age\":25}"
  let responses = [text_response_json(json_text)]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: NativeStrategy,
      max_retries: 3,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Bob")
  user.age |> should.equal(25)
}

// ============================================================================
// Tests: Retry — validation error then correction
// ============================================================================

pub fn tool_call_retry_on_validation_error_test() {
  let output = user_schema()

  // First response: missing "age" field
  let bad_args = "{\"name\":\"Charlie\"}"
  // Second response: correct
  let good_args = "{\"name\":\"Charlie\",\"age\":28}"

  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: bad_args,
      call_id: "call_1",
    ),
    tool_call_response_json(
      tool_name: "user",
      args_json: good_args,
      call_id: "call_2",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 3,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Charlie")
  user.age |> should.equal(28)
}

pub fn native_retry_on_validation_error_test() {
  let output = user_schema()

  // First response: wrong type for age (string instead of int)
  let bad_json = "{\"name\":\"Dana\",\"age\":\"twenty\"}"
  // Second response: correct
  let good_json = "{\"name\":\"Dana\",\"age\":20}"

  let responses = [text_response_json(bad_json), text_response_json(good_json)]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: NativeStrategy,
      max_retries: 3,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Dana")
  user.age |> should.equal(20)
}

// ============================================================================
// Tests: Max retries exceeded
// ============================================================================

pub fn max_retries_exceeded_test() {
  let output = user_schema()
  let bad_args = "{\"name\":\"Eve\"}"

  // All responses are invalid — missing "age"
  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: bad_args,
      call_id: "call_1",
    ),
    tool_call_response_json(
      tool_name: "user",
      args_json: bad_args,
      call_id: "call_2",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 1,
      send_fn: mock_send_sequence(responses: responses),
    )

  result |> should.be_error
  let assert Error(structured_output.MaxRetriesExceeded(last_errors:)) = result
  // Should have error about missing field
  let error_text = string.join(last_errors, " ")
  error_text |> string.contains("age") |> should.be_true
}

// ============================================================================
// Tests: Markdown fence stripping
// ============================================================================

pub fn strip_markdown_fences_json_block_test() {
  let input = "```json\n{\"name\":\"Alice\",\"age\":30}\n```"
  let result = structured_output.strip_markdown_fences(input)
  result |> should.equal("{\"name\":\"Alice\",\"age\":30}")
}

pub fn strip_markdown_fences_plain_block_test() {
  let input = "```\n{\"key\":\"value\"}\n```"
  let result = structured_output.strip_markdown_fences(input)
  result |> should.equal("{\"key\":\"value\"}")
}

pub fn strip_markdown_fences_no_fences_test() {
  let input = "{\"name\":\"Bob\"}"
  let result = structured_output.strip_markdown_fences(input)
  result |> should.equal("{\"name\":\"Bob\"}")
}

pub fn tool_call_extract_with_markdown_fences_test() {
  let output = user_schema()
  // LLM wraps JSON in markdown fences (common with some models)
  let args = "```json\n{\"name\":\"Frank\",\"age\":40}\n```"
  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: args,
      call_id: "call_1",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Frank")
  user.age |> should.equal(40)
}

// ============================================================================
// Tests: Scalar wrapping — simple types need object wrapping
// ============================================================================

pub fn scalar_extraction_test() {
  // Scalar types need to be wrapped in an object for structured output.
  // The caller wraps them in a single-field object schema.
  let schema = {
    use value <- sextant.field("value", sextant.string())
    sextant.success(value)
  }
  let output =
    OutputSchema(
      name: "extract_value",
      description: "Extract a single value",
      schema: schema,
    )

  let args = "{\"value\":\"hello world\"}"
  let responses = [
    tool_call_response_json(
      tool_name: "extract_value",
      args_json: args,
      call_id: "call_1",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(value) = result
  value |> should.equal("hello world")
}

// ============================================================================
// Tests: Send error
// ============================================================================

pub fn send_error_test() {
  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: user_schema(),
      strategy: ToolCallStrategy,
      max_retries: 3,
      send_fn: fn(_) { Error("connection refused") },
    )

  result |> should.be_error
  let assert Error(structured_output.SendError("connection refused")) = result
}

// ============================================================================
// Tests: Empty response
// ============================================================================

pub fn empty_response_test() {
  let output = user_schema()
  let empty_response =
    "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: [empty_response]),
    )

  result |> should.be_error
  let assert Error(structured_output.EmptyResponse) = result
}

// ============================================================================
// Tests: Existing messages are forwarded
// ============================================================================

pub fn existing_messages_forwarded_test() {
  let output = user_schema()
  let args = "{\"name\":\"Grace\",\"age\":35}"

  // Provide existing conversation messages
  let messages = [
    message.Request(parts: [
      message.SystemPart(content: "You extract user data"),
    ]),
    message.Request(parts: [
      message.UserPart(content: "Extract info from: Grace is 35 years old"),
    ]),
  ]

  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: args,
      call_id: "call_1",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: messages,
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: responses),
    )

  let assert Ok(user) = result
  user.name |> should.equal("Grace")
  user.age |> should.equal(35)
}

// ============================================================================
// Tests: Native strategy with no text returns UnexpectedResponse
// ============================================================================

pub fn native_no_text_returns_unexpected_test() {
  let output = user_schema()

  // Response with tool call instead of text — wrong for native strategy
  let responses = [
    tool_call_response_json(
      tool_name: "user",
      args_json: "{\"name\":\"X\",\"age\":1}",
      call_id: "call_1",
    ),
  ]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: NativeStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: responses),
    )

  result |> should.be_error
  let assert Error(structured_output.UnexpectedResponse(_)) = result
}

// ============================================================================
// Tests: Tool-call strategy with text-only response returns UnexpectedResponse
// ============================================================================

pub fn tool_call_no_tool_returns_unexpected_test() {
  let output = user_schema()
  let responses = [text_response_json("{\"name\":\"X\",\"age\":1}")]

  let result =
    structured_output.extract(
      config: test_config(),
      messages: [],
      output: output,
      strategy: ToolCallStrategy,
      max_retries: 0,
      send_fn: mock_send_sequence(responses: responses),
    )

  result |> should.be_error
  let assert Error(structured_output.UnexpectedResponse(_)) = result
}
