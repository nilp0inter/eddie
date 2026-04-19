/// The widget abstraction — Elm-architecture components that compose into
/// a shared context between a user and an AI agent.
///
/// Each widget has:
/// - A **model** (immutable state)
/// - **Msgs** (typed events)
/// - An **update** function: `(model, msg) -> #(model, Cmd(msg))`
/// - Three **view** functions: messages (for LLM), tools (for LLM), state (for frontend)
/// - Two **anticorruption layers**: from_llm and from_ui convert external
///   events into typed Msgs
///
/// `WidgetHandle` is the type-erased interface that Context works with.
/// It uses closures to hide the concrete model and msg types while
/// preserving type safety within each widget's boundary.
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

import eddie/cmd.{type Cmd, CmdEffect, CmdNone, CmdToolResult}
import eddie/coerce
import eddie/tool.{type ToolDefinition}
import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

/// Result of dispatching an LLM tool call through a widget.
/// Completed means the tool call finished synchronously.
/// EffectPending means an async effect needs to run before completion.
pub type DispatchResult {
  Completed(handle: WidgetHandle, result: Result(String, String))
  EffectPending(
    handle: WidgetHandle,
    perform: fn() -> Dynamic,
    resume: fn(Dynamic) -> DispatchResult,
  )
}

/// Run a DispatchResult to completion synchronously.
/// For Completed, returns immediately. For EffectPending, runs the
/// effect inline and feeds the result back, repeating until Completed.
pub fn resolve(
  dispatch_result dispatch_result: DispatchResult,
) -> #(WidgetHandle, Result(String, String)) {
  case dispatch_result {
    Completed(handle, result) -> #(handle, result)
    EffectPending(_handle, perform, resume) -> {
      let data = perform()
      resolve(dispatch_result: resume(data))
    }
  }
}

/// Extract the widget handle from a DispatchResult regardless of variant.
pub fn dispatch_result_handle(
  dispatch_result dispatch_result: DispatchResult,
) -> WidgetHandle {
  case dispatch_result {
    Completed(handle, _) -> handle
    EffectPending(handle, _, _) -> handle
  }
}

/// Configuration for creating a widget. All functions are required except
/// where defaults make sense (e.g. a widget with no tools).
pub type WidgetConfig(model, msg) {
  WidgetConfig(
    id: String,
    model: model,
    update: fn(model, msg) -> #(model, Cmd(msg)),
    view_messages: fn(model) -> List(Message),
    view_tools: fn(model) -> List(ToolDefinition),
    view_state: fn(model) -> List(ServerEvent),
    from_llm: fn(model, String, Dynamic) -> Result(msg, String),
    from_ui: fn(model, String, Dynamic) -> Option(msg),
    frontend_tools: Set(String),
    protocol_free_tools: Set(String),
  )
}

/// Errors that can occur when sending a message directly to a widget.
pub type SendError {
  /// The widget's update function produced a command other than CmdNone,
  /// which is not allowed for direct sends.
  UnexpectedCommand
}

/// Type-erased widget handle. Context holds a list of these.
/// Internally wraps a typed widget via closures — the concrete model and
/// msg types are hidden but all operations remain type-safe within the
/// widget's boundary.
pub opaque type WidgetHandle {
  WidgetHandle(
    id: String,
    view_messages_fn: fn() -> List(Message),
    view_tools_fn: fn() -> List(ToolDefinition),
    view_state_fn: fn() -> List(ServerEvent),
    dispatch_llm_fn: fn(String, Dynamic) -> DispatchResult,
    dispatch_ui_fn: fn(String, Dynamic) -> #(WidgetHandle, Option(String)),
    send_fn: fn(Dynamic) -> Result(WidgetHandle, SendError),
    frontend_tool_names: Set(String),
    protocol_free_tool_names: Set(String),
  )
}

// ============================================================================
// WidgetHandle accessors
// ============================================================================

/// The widget's unique identifier.
pub fn id(handle: WidgetHandle) -> String {
  handle.id
}

/// Produce the list of messages this widget contributes to the LLM context.
pub fn view_messages(handle: WidgetHandle) -> List(Message) {
  { handle.view_messages_fn }()
}

/// Produce the list of tool definitions this widget exposes to the LLM.
pub fn view_tools(handle: WidgetHandle) -> List(ToolDefinition) {
  { handle.view_tools_fn }()
}

/// Produce the list of domain events representing this widget's current state.
pub fn view_state(handle: WidgetHandle) -> List(ServerEvent) {
  { handle.view_state_fn }()
}

/// Tool names that can be called from the browser frontend.
pub fn frontend_tools(handle: WidgetHandle) -> Set(String) {
  handle.frontend_tool_names
}

/// Tool names exempt from the task protocol (callable without active task).
pub fn protocol_free_tools(handle: WidgetHandle) -> Set(String) {
  handle.protocol_free_tool_names
}

/// Dispatch an LLM tool call through the widget.
/// Runs from_llm -> update -> Cmd loop.
/// Returns a DispatchResult: either Completed or EffectPending.
pub fn dispatch_llm(
  handle handle: WidgetHandle,
  tool_name tool_name: String,
  args args: Dynamic,
) -> DispatchResult {
  { handle.dispatch_llm_fn }(tool_name, args)
}

/// Dispatch a browser UI event through the widget.
/// Returns the updated handle and Some(result) if handled, None if not.
pub fn dispatch_ui(
  handle handle: WidgetHandle,
  event_name event_name: String,
  args args: Dynamic,
) -> #(WidgetHandle, Option(String)) {
  { handle.dispatch_ui_fn }(event_name, args)
}

/// Send a message directly, bypassing anticorruption layers.
/// The message must be coerced to Dynamic by the caller.
/// Returns Error if the widget's update produces a command other than CmdNone.
pub fn send(
  handle handle: WidgetHandle,
  msg msg: Dynamic,
) -> Result(WidgetHandle, SendError) {
  { handle.send_fn }(msg)
}

// ============================================================================
// Internal: bundled function table to reduce parameter passing
// ============================================================================

/// All the functions that define a widget's behavior, bundled together
/// so we don't pass 8 parameters to every internal function.
type WidgetFns(model, msg) {
  WidgetFns(
    id: String,
    update: fn(model, msg) -> #(model, Cmd(msg)),
    view_messages: fn(model) -> List(Message),
    view_tools: fn(model) -> List(ToolDefinition),
    view_state: fn(model) -> List(ServerEvent),
    from_llm: fn(model, String, Dynamic) -> Result(msg, String),
    from_ui: fn(model, String, Dynamic) -> Option(msg),
    frontend_tools: Set(String),
    protocol_free_tools: Set(String),
  )
}

// ============================================================================
// Factory: create a WidgetHandle from a typed WidgetConfig
// ============================================================================

/// Create a type-erased WidgetHandle from a typed WidgetConfig.
/// The closures capture the concrete model and msg types internally.
pub fn create(config: WidgetConfig(model, msg)) -> WidgetHandle {
  let initial_model = config.model
  let fns =
    WidgetFns(
      id: config.id,
      update: config.update,
      view_messages: config.view_messages,
      view_tools: config.view_tools,
      view_state: config.view_state,
      from_llm: config.from_llm,
      from_ui: config.from_ui,
      frontend_tools: config.frontend_tools,
      protocol_free_tools: config.protocol_free_tools,
    )
  build_handle(fns: fns, model: initial_model)
}

/// Build a WidgetHandle with closures capturing the typed state.
fn build_handle(
  fns fns: WidgetFns(model, msg),
  model model: model,
) -> WidgetHandle {
  WidgetHandle(
    id: fns.id,
    view_messages_fn: fn() { { fns.view_messages }(model) },
    view_tools_fn: fn() { { fns.view_tools }(model) },
    view_state_fn: fn() { { fns.view_state }(model) },
    dispatch_llm_fn: fn(tool_name, args) {
      do_dispatch_llm(fns: fns, model: model, tool_name: tool_name, args: args)
    },
    dispatch_ui_fn: fn(event_name, args) {
      do_dispatch_ui(fns: fns, model: model, event_name: event_name, args: args)
    },
    send_fn: fn(dynamic_msg) {
      do_send(fns: fns, model: model, dynamic_msg: dynamic_msg)
    },
    frontend_tool_names: fns.frontend_tools,
    protocol_free_tool_names: fns.protocol_free_tools,
  )
}

/// Handle LLM tool call dispatch: from_llm -> update -> Cmd loop.
fn do_dispatch_llm(
  fns fns: WidgetFns(model, msg),
  model model: model,
  tool_name tool_name: String,
  args args: Dynamic,
) -> DispatchResult {
  case { fns.from_llm }(model, tool_name, args) {
    Error(err) ->
      Completed(
        handle: build_handle(fns: fns, model: model),
        result: Error(err),
      )
    Ok(msg) -> {
      let #(new_model, cmd) = { fns.update }(model, msg)
      execute_cmd_loop(fns: fns, model: new_model, cmd: cmd)
    }
  }
}

/// Handle UI event dispatch: check frontend tools -> from_ui -> update -> Cmd loop.
fn do_dispatch_ui(
  fns fns: WidgetFns(model, msg),
  model model: model,
  event_name event_name: String,
  args args: Dynamic,
) -> #(WidgetHandle, Option(String)) {
  let is_frontend = set.contains(fns.frontend_tools, event_name)
  use <- bool.guard(when: !is_frontend, return: #(
    build_handle(fns: fns, model: model),
    None,
  ))
  do_dispatch_ui_event(
    fns: fns,
    model: model,
    event_name: event_name,
    args: args,
  )
}

/// Process a validated frontend UI event.
fn do_dispatch_ui_event(
  fns fns: WidgetFns(model, msg),
  model model: model,
  event_name event_name: String,
  args args: Dynamic,
) -> #(WidgetHandle, Option(String)) {
  case { fns.from_ui }(model, event_name, args) {
    None -> #(build_handle(fns: fns, model: model), None)
    Some(msg) -> {
      let #(new_model, cmd) = { fns.update }(model, msg)
      // UI events run synchronously — resolve any effects inline
      let #(handle, result) =
        resolve(dispatch_result: execute_cmd_loop(
          fns: fns,
          model: new_model,
          cmd: cmd,
        ))
      // UI dispatches convert Ok to Some, and discard errors as None
      // because UI events don't have a channel to report errors through
      let ui_result = option.from_result(result)
      #(handle, ui_result)
    }
  }
}

/// Handle direct message send (bypasses anticorruption layers).
fn do_send(
  fns fns: WidgetFns(model, msg),
  model model: model,
  dynamic_msg dynamic_msg: Dynamic,
) -> Result(WidgetHandle, SendError) {
  // unsafe_coerce is needed because we erase the msg type at the
  // WidgetHandle boundary. This is safe because send() is only
  // called by code that knows the concrete msg type.
  let msg: msg = coerce.unsafe_coerce(dynamic_msg)
  let #(new_model, cmd) = { fns.update }(model, msg)
  case cmd {
    CmdNone -> Ok(build_handle(fns: fns, model: new_model))
    _ -> Error(UnexpectedCommand)
  }
}

/// Execute the Cmd loop: CmdNone returns Completed with empty result,
/// CmdToolResult returns Completed with text, CmdEffect returns
/// EffectPending with the perform thunk and a resume continuation.
fn execute_cmd_loop(
  fns fns: WidgetFns(model, msg),
  model model: model,
  cmd cmd: Cmd(msg),
) -> DispatchResult {
  case cmd {
    CmdNone ->
      Completed(handle: build_handle(fns: fns, model: model), result: Ok(""))
    CmdToolResult(text) ->
      Completed(handle: build_handle(fns: fns, model: model), result: Ok(text))
    CmdEffect(perform, to_msg) ->
      EffectPending(
        handle: build_handle(fns: fns, model: model),
        perform: perform,
        resume: fn(data) {
          let msg = to_msg(data)
          let #(new_model, next_cmd) = { fns.update }(model, msg)
          execute_cmd_loop(fns: fns, model: new_model, cmd: next_cmd)
        },
      )
  }
}
