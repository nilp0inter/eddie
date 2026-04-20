import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit/should

import eddie/agent
import eddie/http as eddie_http
import eddie/llm

// ============================================================================
// Mock LLM response helpers
// ============================================================================

fn mock_response(json_body: String) -> Response(String) {
  response.new(200) |> response.set_body(json_body)
}

fn text_response_json(text: String) -> String {
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\""
  <> text
  <> "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}

fn tool_call_response_json(
  tool_name: String,
  args_json: String,
  call_id: String,
) -> String {
  "{\"id\":\"chatcmpl-2\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\""
  <> call_id
  <> "\",\"type\":\"function\",\"function\":{\"name\":\""
  <> tool_name
  <> "\",\"arguments\":\""
  <> escape_json_string(args_json)
  <> "\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}

fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

fn test_config() -> agent.AgentConfig {
  agent.AgentConfig(
    agent_id: "test-agent",
    llm_config: llm.LlmConfig(
      api_base: "https://test.example.com/v1",
      api_key: "test-key",
      model: "test-model",
    ),
    system_prompt: "You are a test assistant.",
    extra_widgets: [],
    on_turn_complete: option.None,
  )
}

fn mock_http_error() -> eddie_http.HttpError {
  eddie_http.RequestFailed(httpc.ResponseTimeout)
}

// ============================================================================
// Response queue actor — holds a list of responses, serves them one at a time
// via process.call so any process can consume from it.
// ============================================================================

type QueueMsg {
  GetNext(
    reply_to: process.Subject(Result(Response(String), eddie_http.HttpError)),
  )
}

fn start_response_queue(
  responses: List(Result(Response(String), eddie_http.HttpError)),
) -> process.Subject(QueueMsg) {
  let assert Ok(started) =
    actor.new(responses)
    |> actor.on_message(fn(state, msg) {
      case msg {
        GetNext(reply_to) ->
          case state {
            [first, ..rest] -> {
              process.send(reply_to, first)
              actor.continue(rest)
            }
            [] -> {
              process.send(reply_to, Error(mock_http_error()))
              actor.continue([])
            }
          }
      }
    })
    |> actor.start
  started.data
}

/// Create a mock send function backed by a response queue actor.
fn mock_send_fn(
  responses: List(Result(Response(String), eddie_http.HttpError)),
) -> fn(Request(String)) -> Result(Response(String), eddie_http.HttpError) {
  let queue = start_response_queue(responses)
  fn(_request) {
    process.call(queue, waiting: 10_000, sending: fn(reply_to) {
      GetNext(reply_to:)
    })
  }
}

// ============================================================================
// Tests: Simple text response
// ============================================================================

pub fn simple_text_response_test() {
  let send_fn =
    mock_send_fn([Ok(mock_response(text_response_json("Hello, world!")))])

  let assert Ok(subject) =
    agent.start_with_send_fn(config: test_config(), send_fn: send_fn)

  let result = agent.run_turn(subject: subject, text: "Hi", timeout: 10_000)

  case result {
    agent.TurnSuccess(text) -> text |> should.equal("Hello, world!")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

// ============================================================================
// Tests: Tool call dispatch (create_task)
// ============================================================================

pub fn tool_call_creates_task_test() {
  let send_fn =
    mock_send_fn([
      Ok(
        mock_response(tool_call_response_json(
          "create_task",
          "{\\\"description\\\":\\\"Test task\\\"}",
          "call_1",
        )),
      ),
      Ok(mock_response(text_response_json("Task created!"))),
    ])

  let assert Ok(subject) =
    agent.start_with_send_fn(config: test_config(), send_fn: send_fn)

  let result =
    agent.run_turn(subject: subject, text: "Create a task", timeout: 10_000)

  case result {
    agent.TurnSuccess(text) -> text |> should.equal("Task created!")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

// ============================================================================
// Tests: Full task lifecycle (create -> start -> memory -> close -> text)
// ============================================================================

pub fn full_task_lifecycle_test() {
  let send_fn =
    mock_send_fn([
      // 1. Create task + start task
      Ok(
        mock_response(two_tool_call_response_json(
          "create_task",
          "{\\\"description\\\":\\\"Do work\\\"}",
          "call_c1",
          "start_task",
          "{\\\"task_id\\\":1}",
          "call_s1",
        )),
      ),
      // 2. Record memory
      Ok(
        mock_response(tool_call_response_json(
          "task_memory",
          "{\\\"text\\\":\\\"Found important thing\\\"}",
          "call_m1",
        )),
      ),
      // 3. Close task
      Ok(
        mock_response(tool_call_response_json(
          "close_current_task",
          "{}",
          "call_cl1",
        )),
      ),
      // 4. Final text
      Ok(mock_response(text_response_json("Done with the task!"))),
    ])

  let assert Ok(subject) =
    agent.start_with_send_fn(config: test_config(), send_fn: send_fn)

  let result =
    agent.run_turn(subject: subject, text: "Do work", timeout: 15_000)

  case result {
    agent.TurnSuccess(text) -> text |> should.equal("Done with the task!")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

// ============================================================================
// Tests: HTTP error returns TurnError
// ============================================================================

pub fn http_error_returns_turn_error_test() {
  let send_fn = mock_send_fn([Error(mock_http_error())])

  let assert Ok(subject) =
    agent.start_with_send_fn(config: test_config(), send_fn: send_fn)

  let result = agent.run_turn(subject: subject, text: "Hello", timeout: 10_000)

  case result {
    agent.TurnError(_) -> should.be_true(True)
    agent.TurnSuccess(_) -> should.fail()
  }
}

// ============================================================================
// Tests: Subscriber receives HTML updates
// ============================================================================

pub fn subscriber_receives_html_updates_test() {
  let send_fn = mock_send_fn([Ok(mock_response(text_response_json("Reply")))])

  let assert Ok(subject) =
    agent.start_with_send_fn(config: test_config(), send_fn: send_fn)

  // Subscribe to HTML updates
  let html_subject = process.new_subject()
  agent.subscribe(subject: subject, subscriber: html_subject)

  // Small delay to ensure subscribe is processed
  process.sleep(50)

  let _result = agent.run_turn(subject: subject, text: "Hello", timeout: 10_000)

  // We should have received at least one HTML update
  let received = drain_subject(html_subject, 200, [])
  list.is_empty(received) |> should.be_false
}

fn drain_subject(
  subject: process.Subject(String),
  timeout: Int,
  accumulator: List(String),
) -> List(String) {
  case process.receive(subject, timeout) {
    Ok(msg) -> drain_subject(subject, timeout, [msg, ..accumulator])
    Error(_) -> accumulator
  }
}

// ============================================================================
// Multi-tool-call response helper
// ============================================================================

fn two_tool_call_response_json(
  name1: String,
  args1: String,
  id1: String,
  name2: String,
  args2: String,
  id2: String,
) -> String {
  "{\"id\":\"chatcmpl-3\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\""
  <> id1
  <> "\",\"type\":\"function\",\"function\":{\"name\":\""
  <> name1
  <> "\",\"arguments\":\""
  <> args1
  <> "\"}},{\"id\":\""
  <> id2
  <> "\",\"type\":\"function\",\"function\":{\"name\":\""
  <> name2
  <> "\",\"arguments\":\""
  <> args2
  <> "\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}
