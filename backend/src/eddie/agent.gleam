/// Agent — reactive OTP actor that manages the LLM turn loop.
///
/// The agent reacts to messages without blocking. LLM calls and tool
/// effects are spawned as async processes. User messages arriving
/// during a turn are queued and processed after the current turn.
///
/// Subscribers (WebSocket processes) receive JSON-encoded ServerEvent
/// lists after each state mutation so the browser stays in sync.
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

import eddie/coerce
import eddie/context.{type Context}
import eddie/http as eddie_http
import eddie/llm.{type LlmConfig}
import eddie/widget.{type WidgetHandle}
import eddie/widgets/conversation_log as eddie_conversation_log
import eddie/widgets/file_explorer as eddie_file_explorer
import eddie/widgets/goal as eddie_goal
import eddie/widgets/system_prompt as eddie_system_prompt
import eddie/widgets/token_usage as eddie_token_usage
import eddie_shared/message.{type Message}
import eddie_shared/protocol
import eddie_shared/turn_result as shared_turn_result

/// Configuration for creating an agent.
pub type AgentConfig {
  AgentConfig(
    agent_id: String,
    llm_config: LlmConfig,
    system_prompt: String,
    /// Extra widget handles injected by the caller (e.g. mailbox, subagent_manager).
    /// This avoids import cycles — agent.gleam doesn't need to know about specific widgets.
    extra_widgets: List(WidgetHandle),
  )
}

/// Partial overrides for child agent configuration.
/// None fields inherit from the parent.
pub type AgentConfigOverride {
  AgentConfigOverride(
    model: Option(String),
    api_base: Option(String),
    system_prompt: Option(String),
  )
}

/// Merge a parent config with an override to produce a child config.
/// None fields in the override inherit from the parent.
pub fn merge_config(
  parent parent: AgentConfig,
  child_id child_id: String,
  override override: AgentConfigOverride,
) -> AgentConfig {
  AgentConfig(
    agent_id: child_id,
    llm_config: llm.LlmConfig(
      api_base: option.unwrap(override.api_base, parent.llm_config.api_base),
      api_key: parent.llm_config.api_key,
      model: option.unwrap(override.model, parent.llm_config.model),
    ),
    system_prompt: option.unwrap(override.system_prompt, parent.system_prompt),
    extra_widgets: [],
  )
}

/// Result of a turn.
pub type TurnResult {
  TurnSuccess(text: String)
  TurnError(reason: String)
}

/// Messages the agent actor handles.
pub opaque type AgentMessage {
  // User-facing messages
  UserMessage(text: String, reply_to: Option(Subject(TurnResult)))
  GetState(reply_to: Subject(Context))
  GetCurrentState(reply_to: Subject(String))
  Subscribe(subscriber: Subject(String))
  Unsubscribe(subscriber: Subject(String))
  DispatchEvent(event_name: String, args_json: String)
  // Internal — from spawned async processes
  LlmResponse(response: Response(String))
  LlmError(reason: String)
  ToolEffectResult(call_id: String, data: Dynamic)
  ToolEffectCrashed(call_id: String, reason: String)
  // Init — agent learns its own subject
  SetSelf(subject: Subject(AgentMessage))
}

/// Continuation for a pending tool effect.
type EffectContinuation {
  EffectContinuation(
    tool_name: String,
    tool_call_id: String,
    owner_id: String,
    resume: fn(Dynamic) -> widget.DispatchResult,
  )
}

/// Internal actor state.
type AgentState {
  AgentState(
    context: Context,
    config: LlmConfig,
    subscribers: List(Subject(String)),
    send_fn: fn(Request(String)) ->
      Result(Response(String), eddie_http.HttpError),
    // Agent's own subject for spawned processes to send back to
    self: Option(Subject(AgentMessage)),
    // Async bookkeeping
    llm_in_flight: Bool,
    pending_user_messages: List(#(String, Option(Subject(TurnResult)))),
    pending_effects: Dict(String, EffectContinuation),
    collected_tool_parts: List(message.MessagePart),
    current_reply_to: Option(Subject(TurnResult)),
    iteration: Int,
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
  let ctx = build_context(config: config)
  let initial_state =
    AgentState(
      context: ctx,
      config: config.llm_config,
      subscribers: [],
      send_fn: send_fn,
      self: None,
      llm_in_flight: False,
      pending_user_messages: [],
      pending_effects: dict.new(),
      collected_tool_parts: [],
      current_reply_to: None,
      iteration: 0,
    )
  let result =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> {
      // Tell the agent its own subject so spawned processes can send back
      process.send(started.data, SetSelf(subject: started.data))
      Ok(started.data)
    }
    Error(err) -> Error(err)
  }
}

/// Send a user message and wait for the agent to complete the turn.
/// The caller blocks but the agent processes asynchronously.
pub fn run_turn(
  subject subject: Subject(AgentMessage),
  text text: String,
  timeout timeout: Int,
) -> TurnResult {
  process.call(subject, waiting: timeout, sending: fn(reply_to) {
    UserMessage(text: text, reply_to: Some(reply_to))
  })
}

/// Send a user message (fire-and-forget, no reply).
pub fn send_message(
  subject subject: Subject(AgentMessage),
  text text: String,
) -> Nil {
  process.send(subject, UserMessage(text: text, reply_to: None))
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

/// Get the current state events for all widgets as a JSON string.
pub fn get_current_state(
  subject subject: Subject(AgentMessage),
  timeout timeout: Int,
) -> String {
  process.call(subject, waiting: timeout, sending: fn(reply_to) {
    GetCurrentState(reply_to:)
  })
}

/// Register a subscriber to receive state updates as JSON strings.
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
    SetSelf(subject) -> actor.continue(AgentState(..state, self: Some(subject)))

    UserMessage(text, reply_to) ->
      actor.continue(handle_user_message(state, text, reply_to))

    GetState(reply_to) -> {
      process.send(reply_to, state.context)
      actor.continue(state)
    }

    GetCurrentState(reply_to) -> {
      let events = context.current_state(context: state.context)
      let payload = protocol.server_events_to_json_string(events)
      process.send(reply_to, payload)
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

    LlmResponse(response) ->
      actor.continue(handle_llm_response(state, response))

    LlmError(reason) -> actor.continue(handle_llm_error(state, reason))

    ToolEffectResult(call_id, data) ->
      actor.continue(handle_tool_effect_result(state, call_id, data))

    ToolEffectCrashed(call_id, reason) ->
      actor.continue(handle_tool_effect_crashed(state, call_id, reason))
  }
}

// ============================================================================
// Reactive message handlers
// ============================================================================

fn handle_user_message(
  state state: AgentState,
  text text: String,
  reply_to reply_to: Option(Subject(TurnResult)),
) -> AgentState {
  let is_busy = state.llm_in_flight || !dict.is_empty(state.pending_effects)
  case is_busy {
    True ->
      // Queue the message for later
      AgentState(
        ..state,
        pending_user_messages: list.append(state.pending_user_messages, [
          #(text, reply_to),
        ]),
      )
    False -> {
      // Process immediately
      let old_ctx = state.context
      let new_ctx = context.add_user_message(context: state.context, text: text)
      let state =
        AgentState(
          ..state,
          context: new_ctx,
          current_reply_to: reply_to,
          iteration: 0,
        )
      notify_subscribers(state: state, old_context: old_ctx)
      start_llm_call(state)
    }
  }
}

fn handle_llm_response(
  state: AgentState,
  response: Response(String),
) -> AgentState {
  let state = AgentState(..state, llm_in_flight: False)

  case llm.parse_response(response: response) {
    Error(err) ->
      complete_turn(state, TurnError(reason: llm_error_to_string(err)))

    Ok(#(eddie_response, usage)) -> {
      let state = record_token_usage(state: state, usage: usage)

      let old_ctx = state.context
      let ctx = context.consume_picks(context: state.context)
      let ctx = context.add_response(context: ctx, response: eddie_response)
      let state = AgentState(..state, context: ctx)
      notify_subscribers(state: state, old_context: old_ctx)

      let tool_calls = extract_tool_calls(eddie_response)
      case tool_calls {
        [] -> {
          let text = extract_text(eddie_response)
          complete_turn(state, TurnSuccess(text: text))
        }
        _ -> dispatch_tool_calls(state, tool_calls)
      }
    }
  }
}

fn handle_llm_error(state: AgentState, reason: String) -> AgentState {
  let state = AgentState(..state, llm_in_flight: False)
  complete_turn(state, TurnError(reason: reason))
}

fn handle_tool_effect_result(
  state state: AgentState,
  call_id call_id: String,
  data data: Dynamic,
) -> AgentState {
  case dict.get(state.pending_effects, call_id) {
    Error(Nil) -> state
    Ok(continuation) -> {
      let state =
        AgentState(
          ..state,
          pending_effects: dict.delete(state.pending_effects, call_id),
        )
      resolve_effect_result(
        state: state,
        call_id: call_id,
        continuation: continuation,
        dispatch_result: { continuation.resume }(data),
      )
    }
  }
}

/// Process the result of a resumed effect continuation.
fn resolve_effect_result(
  state state: AgentState,
  call_id call_id: String,
  continuation continuation: EffectContinuation,
  dispatch_result dispatch_result: widget.DispatchResult,
) -> AgentState {
  case dispatch_result {
    widget.Completed(handle, result) -> {
      let result_text = case result {
        Ok(text) -> text
        Error(err) -> err
      }

      let new_ctx =
        context.replace_widget(
          context: state.context,
          owner_id: continuation.owner_id,
          handle: handle,
        )
      let state = AgentState(..state, context: new_ctx)

      notify_tool_result(
        state: state,
        tool_name: continuation.tool_name,
        tool_call_id: continuation.tool_call_id,
        result: result_text,
      )

      let part =
        message.ToolReturnPart(
          tool_name: continuation.tool_name,
          content: result_text,
          tool_call_id: continuation.tool_call_id,
        )
      AgentState(..state, collected_tool_parts: [
        part,
        ..state.collected_tool_parts
      ])
      |> maybe_continue_after_effects
    }

    widget.EffectPending(handle, perform, resume) -> {
      let new_ctx =
        context.replace_widget(
          context: state.context,
          owner_id: continuation.owner_id,
          handle: handle,
        )
      let new_continuation = EffectContinuation(..continuation, resume: resume)
      let state =
        AgentState(
          ..state,
          context: new_ctx,
          pending_effects: dict.insert(
            state.pending_effects,
            call_id,
            new_continuation,
          ),
        )
      spawn_effect(state, call_id, perform)
      state
    }
  }
}

fn handle_tool_effect_crashed(
  state state: AgentState,
  call_id call_id: String,
  reason reason: String,
) -> AgentState {
  case dict.get(state.pending_effects, call_id) {
    Error(Nil) -> state
    Ok(continuation) -> {
      let state =
        AgentState(
          ..state,
          pending_effects: dict.delete(state.pending_effects, call_id),
        )

      let error_text = "Effect error: " <> reason

      // Notify about tool completion with error
      notify_tool_result(
        state: state,
        tool_name: continuation.tool_name,
        tool_call_id: continuation.tool_call_id,
        result: error_text,
      )

      let part =
        message.ToolReturnPart(
          tool_name: continuation.tool_name,
          content: error_text,
          tool_call_id: continuation.tool_call_id,
        )
      let state =
        AgentState(..state, collected_tool_parts: [
          part,
          ..state.collected_tool_parts
        ])

      maybe_continue_after_effects(state)
    }
  }
}

// ============================================================================
// Turn lifecycle
// ============================================================================

/// Compose and spawn an LLM request. Sets llm_in_flight.
fn start_llm_call(state: AgentState) -> AgentState {
  let assert Some(self) = state.self

  case state.iteration >= 25 {
    True -> complete_turn(state, TurnError(reason: "Max iterations reached"))
    False -> {
      let messages = context.view_messages(context: state.context)
      let tools = context.view_tools(context: state.context)
      let request =
        llm.build_request(
          config: state.config,
          messages: messages,
          tools: tools,
        )

      // Broadcast TurnStarted on the first iteration
      case state.iteration {
        0 -> broadcast_events(state, [protocol.TurnStarted])
        _ -> Nil
      }

      // Spawn async LLM call
      let send_fn = state.send_fn
      let _pid =
        process.spawn(fn() {
          case send_fn(request) {
            Ok(response) -> process.send(self, LlmResponse(response: response))
            Error(err) ->
              process.send(self, LlmError(reason: http_error_to_string(err)))
          }
        })

      AgentState(..state, llm_in_flight: True)
    }
  }
}

/// Dispatch tool calls from an LLM response. Completed calls are
/// collected immediately; pending effects are spawned asynchronously.
fn dispatch_tool_calls(
  state: AgentState,
  tool_calls: List(ToolCall),
) -> AgentState {
  let state = AgentState(..state, collected_tool_parts: [])

  let state =
    list.fold(tool_calls, state, fn(current_state, tc) {
      // Notify about tool call start
      notify_tool_call(state: current_state, tool_call: tc)

      case
        context.handle_tool_call(
          context: current_state.context,
          tool_name: tc.tool_name,
          args: tc.args,
          tool_call_id: tc.tool_call_id,
        )
      {
        context.ToolCompleted(new_ctx, result) -> {
          let result_text = case result {
            Ok(text) -> text
            Error(err) -> err
          }

          notify_tool_result(
            state: current_state,
            tool_name: tc.tool_name,
            tool_call_id: tc.tool_call_id,
            result: result_text,
          )

          let part =
            message.ToolReturnPart(
              tool_name: tc.tool_name,
              content: result_text,
              tool_call_id: tc.tool_call_id,
            )

          AgentState(..current_state, context: new_ctx, collected_tool_parts: [
            part,
            ..current_state.collected_tool_parts
          ])
        }

        context.ToolEffectPending(
          new_ctx,
          _tool_name,
          _tool_call_id,
          owner_id,
          perform,
          resume,
        ) -> {
          let continuation =
            EffectContinuation(
              tool_name: tc.tool_name,
              tool_call_id: tc.tool_call_id,
              owner_id: owner_id,
              resume: resume,
            )
          let new_state =
            AgentState(
              ..current_state,
              context: new_ctx,
              pending_effects: dict.insert(
                current_state.pending_effects,
                tc.tool_call_id,
                continuation,
              ),
            )
          spawn_effect(new_state, tc.tool_call_id, perform)
          new_state
        }
      }
    })

  // Notify subscribers of state changes from tool dispatch
  // (uses the pre-dispatch context for diffing)
  maybe_continue_after_effects(state)
}

/// If all effects are done, record tool results and start next LLM call.
fn maybe_continue_after_effects(state: AgentState) -> AgentState {
  case dict.is_empty(state.pending_effects) {
    False -> state
    True -> {
      // Guard: if no collected parts, nothing to record (shouldn't happen)
      case state.collected_tool_parts {
        [] -> state
        parts -> {
          let tool_results_msg = message.Request(parts: list.reverse(parts))
          let old_ctx = state.context
          let ctx =
            context.add_tool_results(
              context: state.context,
              request: tool_results_msg,
            )
          let state =
            AgentState(..state, context: ctx, collected_tool_parts: [])
          notify_subscribers(state: state, old_context: old_ctx)

          // Start next LLM call
          let state = AgentState(..state, iteration: state.iteration + 1)
          start_llm_call(state)
        }
      }
    }
  }
}

/// Complete a turn: broadcast TurnCompleted, reply to caller, drain queue.
fn complete_turn(state: AgentState, result: TurnResult) -> AgentState {
  // Broadcast TurnCompleted event
  let shared_result = case result {
    TurnSuccess(text) -> shared_turn_result.TurnSuccess(text:)
    TurnError(reason) -> shared_turn_result.TurnError(reason:)
  }
  broadcast_events(state, [protocol.TurnCompleted(result: shared_result)])

  // Reply to caller if present
  case state.current_reply_to {
    Some(reply_to) -> process.send(reply_to, result)
    None -> Nil
  }

  // Reset turn state and drain next queued message
  let state = AgentState(..state, current_reply_to: None)
  drain_pending(state)
}

/// Process the next queued user message, if any.
fn drain_pending(state: AgentState) -> AgentState {
  case state.pending_user_messages {
    [] -> state
    [#(text, reply_to), ..rest] -> {
      let state = AgentState(..state, pending_user_messages: rest)
      let old_ctx = state.context
      let new_ctx = context.add_user_message(context: state.context, text: text)
      let state =
        AgentState(
          ..state,
          context: new_ctx,
          current_reply_to: reply_to,
          iteration: 0,
        )
      notify_subscribers(state: state, old_context: old_ctx)
      start_llm_call(state)
    }
  }
}

/// Spawn a process to run an effect and send the result back to the agent.
fn spawn_effect(
  state: AgentState,
  call_id: String,
  perform: fn() -> Dynamic,
) -> Nil {
  let assert Some(self) = state.self
  let _pid =
    process.spawn(fn() {
      let data = perform()
      process.send(self, ToolEffectResult(call_id: call_id, data: data))
    })
  Nil
}

// ============================================================================
// Subscriber notification
// ============================================================================

/// Notify all subscribers of state changes between old and new context.
fn notify_subscribers(
  state state: AgentState,
  old_context old_context: Context,
) -> Nil {
  let events = context.changed_state(old: old_context, new: state.context)
  case events {
    [] -> Nil
    _ -> broadcast_events(state, events)
  }
}

/// Broadcast a list of events to all subscribers as a JSON string.
fn broadcast_events(
  state: AgentState,
  events: List(protocol.ServerEvent),
) -> Nil {
  let payload = protocol.server_events_to_json_string(events)
  list.each(state.subscribers, fn(sub) { process.send(sub, payload) })
}

/// Notify subscribers about a tool call being made.
fn notify_tool_call(
  state state: AgentState,
  tool_call tool_call: ToolCall,
) -> Nil {
  broadcast_events(state, [
    protocol.ToolCallStarted(
      name: tool_call.tool_name,
      args_json: tool_call.arguments_json,
      call_id: tool_call.tool_call_id,
    ),
  ])
}

/// Notify subscribers about a tool result.
fn notify_tool_result(
  state state: AgentState,
  tool_name tool_name: String,
  tool_call_id tool_call_id: String,
  result result: String,
) -> Nil {
  broadcast_events(state, [
    protocol.ToolCallCompleted(
      name: tool_name,
      result: result,
      call_id: tool_call_id,
    ),
  ])
}

// ============================================================================
// Context construction
// ============================================================================

/// Build a fresh context with default widgets plus any extras from config.
fn build_context(config config: AgentConfig) -> Context {
  let sp = eddie_system_prompt.create(text: config.system_prompt)
  let log = eddie_conversation_log.init()
  let base_children = [
    eddie_goal.create_default(),
    eddie_file_explorer.create(),
    eddie_token_usage.create(),
  ]
  let children = list.append(base_children, config.extra_widgets)
  context.new(system_prompt: sp, children: children, conversation_log: log)
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

/// Send token usage data to the token_usage widget if available.
/// Finds the widget by id and sends a UsageRecorded message via widget.send.
fn record_token_usage(
  state state: AgentState,
  usage usage: Option(llm.TokenUsage),
) -> AgentState {
  case usage {
    None -> state
    Some(token_usage) -> {
      let msg =
        eddie_token_usage.UsageRecorded(
          input_tokens: token_usage.input_tokens,
          output_tokens: token_usage.output_tokens,
        )
      let coerced_msg = coerce.unsafe_coerce(msg)
      let new_children =
        list.map(context.children(context: state.context), fn(child) {
          case widget.id(child) == "token_usage" {
            True ->
              result.unwrap(widget.send(handle: child, msg: coerced_msg), child)
            False -> child
          }
        })
      let new_ctx =
        context.new(
          system_prompt: context.system_prompt(context: state.context),
          children: new_children,
          conversation_log: context.log(context: state.context),
        )
      AgentState(..state, context: new_ctx)
    }
  }
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
