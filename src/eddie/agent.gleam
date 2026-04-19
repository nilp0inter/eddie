/// Agent — OTP actor that runs the LLM turn loop.
///
/// The agent holds a Context (pure state) and an LlmConfig. It processes
/// one turn at a time: user message → LLM call → tool dispatch → repeat
/// until the LLM responds with text only.
///
/// Subscribers (WebSocket processes) receive HTML fragment updates after
/// each state mutation so the browser stays in sync.
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

import eddie/context.{type Context}
import eddie/http as eddie_http
import eddie/llm.{type LlmConfig}
import eddie/message.{type Message}
import eddie/widgets/conversation_log as eddie_conversation_log
import eddie/widgets/system_prompt as eddie_system_prompt

import lustre/element

/// Configuration for creating an agent.
pub type AgentConfig {
  AgentConfig(llm_config: LlmConfig, system_prompt: String)
}

/// Result of a turn.
pub type TurnResult {
  TurnSuccess(text: String)
  TurnError(reason: String)
}

/// Messages the agent actor handles.
pub opaque type AgentMessage {
  RunTurn(text: String, reply_to: Subject(TurnResult))
  GetState(reply_to: Subject(Context))
  Subscribe(subscriber: Subject(String))
  Unsubscribe(subscriber: Subject(String))
  DispatchEvent(event_name: String, args_json: String)
}

/// Internal actor state.
type AgentState {
  AgentState(
    context: Context,
    config: LlmConfig,
    subscribers: List(Subject(String)),
    send_fn: fn(Request(String)) ->
      Result(Response(String), eddie_http.HttpError),
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new agent actor. Returns a Subject for sending messages.
pub fn start(
  config config: AgentConfig,
) -> Result(Subject(AgentMessage), actor.StartError) {
  start_with_send_fn(config: config, send_fn: eddie_http.send)
}

/// Start an agent with an injectable HTTP send function (for testing).
pub fn start_with_send_fn(
  config config: AgentConfig,
  send_fn send_fn: fn(Request(String)) ->
    Result(Response(String), eddie_http.HttpError),
) -> Result(Subject(AgentMessage), actor.StartError) {
  let ctx = build_context(system_prompt: config.system_prompt)
  let initial_state =
    AgentState(
      context: ctx,
      config: config.llm_config,
      subscribers: [],
      send_fn: send_fn,
    )
  let result =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

/// Send a user message and wait for the agent to complete the turn.
pub fn run_turn(
  subject subject: Subject(AgentMessage),
  text text: String,
  timeout timeout: Int,
) -> TurnResult {
  process.call(subject, waiting: timeout, sending: fn(reply_to) {
    RunTurn(text:, reply_to:)
  })
}

/// Get the current context state.
pub fn get_state(
  subject subject: Subject(AgentMessage),
  timeout timeout: Int,
) -> Context {
  process.call(subject, waiting: timeout, sending: fn(reply_to) {
    GetState(reply_to:)
  })
}

/// Register a subscriber to receive HTML updates.
pub fn subscribe(
  subject subject: Subject(AgentMessage),
  subscriber subscriber: Subject(String),
) -> Nil {
  process.send(subject, Subscribe(subscriber:))
}

/// Unregister a subscriber.
pub fn unsubscribe(
  subject subject: Subject(AgentMessage),
  subscriber subscriber: Subject(String),
) -> Nil {
  process.send(subject, Unsubscribe(subscriber:))
}

/// Dispatch a browser widget event through the agent.
pub fn dispatch_event(
  subject subject: Subject(AgentMessage),
  event_name event_name: String,
  args_json args_json: String,
) -> Nil {
  process.send(subject, DispatchEvent(event_name:, args_json:))
}

// ============================================================================
// Actor message handler
// ============================================================================

fn handle_message(
  state: AgentState,
  msg: AgentMessage,
) -> actor.Next(AgentState, AgentMessage) {
  case msg {
    RunTurn(text, reply_to) -> {
      let #(new_state, result) = do_run_turn(state: state, text: text)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    GetState(reply_to) -> {
      process.send(reply_to, state.context)
      actor.continue(state)
    }
    Subscribe(subscriber) -> {
      let new_subs = [subscriber, ..state.subscribers]
      actor.continue(AgentState(..state, subscribers: new_subs))
    }
    Unsubscribe(subscriber) -> {
      let new_subs = list.filter(state.subscribers, fn(s) { s != subscriber })
      actor.continue(AgentState(..state, subscribers: new_subs))
    }
    DispatchEvent(event_name, args_json) -> {
      let args = json_to_dynamic(args_json)
      let old_ctx = state.context
      let new_ctx =
        context.handle_widget_event(
          context: state.context,
          event_name: event_name,
          args: args,
        )
      let new_state = AgentState(..state, context: new_ctx)
      notify_subscribers(state: new_state, old_context: old_ctx)
      actor.continue(new_state)
    }
  }
}

// ============================================================================
// Turn loop — the core agent logic
// ============================================================================

fn do_run_turn(
  state state: AgentState,
  text text: String,
) -> #(AgentState, TurnResult) {
  let old_ctx = state.context
  let new_ctx = context.add_user_message(context: state.context, text: text)
  let state = AgentState(..state, context: new_ctx)
  notify_subscribers(state: state, old_context: old_ctx)
  turn_loop(state: state, max_iterations: 25, iteration: 0)
}

/// The recursive turn loop. Calls the LLM, dispatches tool calls, repeats.
/// Max iterations prevents infinite loops.
fn turn_loop(
  state state: AgentState,
  max_iterations max_iterations: Int,
  iteration iteration: Int,
) -> #(AgentState, TurnResult) {
  use <- bool.guard(when: iteration >= max_iterations, return: #(
    state,
    TurnError(reason: "Max iterations reached"),
  ))
  do_turn_step(state:, max_iterations:, iteration:)
}

fn do_turn_step(
  state state: AgentState,
  max_iterations max_iterations: Int,
  iteration iteration: Int,
) -> #(AgentState, TurnResult) {
  let messages = context.view_messages(context: state.context)
  let tools = context.view_tools(context: state.context)

  let request =
    llm.build_request(config: state.config, messages: messages, tools: tools)
  case { state.send_fn }(request) {
    Error(err) -> #(state, TurnError(reason: http_error_to_string(err)))
    Ok(response) ->
      handle_llm_response(state:, response:, max_iterations:, iteration:)
  }
}

fn handle_llm_response(
  state state: AgentState,
  response response: Response(String),
  max_iterations max_iterations: Int,
  iteration iteration: Int,
) -> #(AgentState, TurnResult) {
  case llm.parse_response(response: response) {
    Error(err) -> #(state, TurnError(reason: llm_error_to_string(err)))
    Ok(eddie_response) -> {
      // Consume picks before adding response
      let old_ctx = state.context
      let ctx = context.consume_picks(context: state.context)
      let ctx = context.add_response(context: ctx, response: eddie_response)
      let state = AgentState(..state, context: ctx)
      notify_subscribers(state: state, old_context: old_ctx)

      let tool_calls = extract_tool_calls(eddie_response)
      case tool_calls {
        [] -> {
          let text = extract_text(eddie_response)
          #(state, TurnSuccess(text: text))
        }
        _ ->
          dispatch_tool_calls(
            state: state,
            tool_calls: tool_calls,
            max_iterations: max_iterations,
            iteration: iteration,
          )
      }
    }
  }
}

/// Dispatch all tool calls, collect results, record them, continue loop.
fn dispatch_tool_calls(
  state state: AgentState,
  tool_calls tool_calls: List(ToolCall),
  max_iterations max_iterations: Int,
  iteration iteration: Int,
) -> #(AgentState, TurnResult) {
  let #(new_state, tool_return_parts) =
    list.fold(tool_calls, #(state, []), fn(acc, tc) {
      let #(current_state, parts) = acc
      let #(updated_ctx, result) =
        context.handle_tool_call(
          context: current_state.context,
          tool_name: tc.tool_name,
          args: tc.args,
          tool_call_id: tc.tool_call_id,
        )
      let result_text = case result {
        Ok(text) -> text
        Error(err) -> err
      }
      let part =
        message.ToolReturnPart(
          tool_name: tc.tool_name,
          content: result_text,
          tool_call_id: tc.tool_call_id,
        )
      let updated_state = AgentState(..current_state, context: updated_ctx)
      #(updated_state, [part, ..parts])
    })

  // Notify after all tool calls dispatched
  notify_subscribers(state: new_state, old_context: state.context)

  // Record tool results in conversation log
  let tool_results_msg = message.Request(parts: list.reverse(tool_return_parts))
  let old_ctx = new_state.context
  let ctx =
    context.add_tool_results(
      context: new_state.context,
      request: tool_results_msg,
    )
  let new_state = AgentState(..new_state, context: ctx)
  notify_subscribers(state: new_state, old_context: old_ctx)

  turn_loop(
    state: new_state,
    max_iterations: max_iterations,
    iteration: iteration + 1,
  )
}

// ============================================================================
// Subscriber notification
// ============================================================================

/// Notify all subscribers of HTML changes between old and new context.
fn notify_subscribers(
  state state: AgentState,
  old_context old_context: Context,
) -> Nil {
  let changes = context.changed_html(old: old_context, new: state.context)
  case changes {
    [] -> Nil
    _ -> {
      let html_payload =
        list.map(changes, fn(change) {
          let #(id, el) = change
          let inner_html = element.to_string(el)
          "<div id=\"widget-"
          <> id
          <> "\" data-swap-oob=\"true\">"
          <> inner_html
          <> "</div>"
        })
        |> string.join("")
      list.each(state.subscribers, fn(sub) { process.send(sub, html_payload) })
    }
  }
}

// ============================================================================
// Context construction
// ============================================================================

/// Build a fresh context with default widgets.
fn build_context(system_prompt system_prompt: String) -> Context {
  let sp = eddie_system_prompt.create(text: system_prompt)
  let log = eddie_conversation_log.init()
  context.new(system_prompt: sp, children: [], conversation_log: log)
}

// ============================================================================
// Helper types and functions
// ============================================================================

/// A parsed tool call from an LLM response.
type ToolCall {
  ToolCall(
    tool_name: String,
    arguments_json: String,
    tool_call_id: String,
    args: dynamic.Dynamic,
  )
}

/// Extract tool calls from a response message.
fn extract_tool_calls(response: Message) -> List(ToolCall) {
  case response {
    message.Response(parts) ->
      list.filter_map(parts, fn(part) {
        case part {
          message.ToolCallPart(tool_name, arguments_json, tool_call_id) ->
            Ok(ToolCall(
              tool_name: tool_name,
              arguments_json: arguments_json,
              tool_call_id: tool_call_id,
              args: json_to_dynamic(arguments_json),
            ))
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Extract text content from a response message.
fn extract_text(response: Message) -> String {
  case response {
    message.Response(parts) ->
      list.filter_map(parts, fn(part) {
        case part {
          message.TextPart(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
      |> string.join("")
    _ -> ""
  }
}

/// Parse a JSON string into a Dynamic value for passing to tool handlers.
/// Falls back to wrapping the raw string as Dynamic if parsing fails.
fn json_to_dynamic(json_string: String) -> Dynamic {
  let identity_decoder =
    decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })
  json.parse(json_string, identity_decoder)
  |> result.unwrap(dynamic.string(json_string))
}

fn http_error_to_string(err: eddie_http.HttpError) -> String {
  let eddie_http.RequestFailed(_) = err
  "HTTP request failed"
}

fn llm_error_to_string(err: llm.LlmError) -> String {
  case err {
    llm.ApiError(_) -> "LLM API error"
    llm.EmptyResponse -> "LLM returned empty response"
  }
}
