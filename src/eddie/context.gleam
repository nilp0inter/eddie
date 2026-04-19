/// Context compositor — the root container that holds all widgets and
/// orchestrates tool dispatch, message composition, and protocol enforcement.
///
/// Context owns:
/// - A system_prompt widget (always first in message order)
/// - Zero or more child widgets (domain-specific)
/// - A conversation_log (typed, not type-erased — Context needs protocol access)
/// - A tool_owners map routing tool names to their owning widget handles
///
/// Tool dispatch flow:
/// 1. Context checks the task protocol via conversation_log.protocol_check
/// 2. If allowed, Context looks up the tool owner in tool_owners
/// 3. Context dispatches to the owner (typed for conversation_log, via WidgetHandle for others)
/// 4. Context rebuilds the tool_owners map (tools may change after state update)
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import lustre/element.{type Element}

import eddie/message.{type Message}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie/widgets/conversation_log.{type ConversationLog}

/// The root context compositor.
pub opaque type Context {
  Context(
    system_prompt: WidgetHandle,
    children: List(WidgetHandle),
    log: ConversationLog,
    tool_owners: Dict(String, String),
    all_protocol_free_tools: Set(String),
  )
}

/// Create a new context from widgets.
/// Builds the tool_owners map by scanning all widgets' current tools.
pub fn new(
  system_prompt system_prompt: WidgetHandle,
  children children: List(WidgetHandle),
  conversation_log log: ConversationLog,
) -> Context {
  let ctx =
    Context(
      system_prompt: system_prompt,
      children: children,
      log: log,
      tool_owners: dict.new(),
      all_protocol_free_tools: set.new(),
    )
  rebuild_tool_owners(ctx)
}

/// Compose messages from all widgets in order:
/// system_prompt → children → conversation_log.
pub fn view_messages(context context: Context) -> List(Message) {
  let system_messages = widget.view_messages(context.system_prompt)
  let child_messages =
    list.flat_map(context.children, fn(child) { widget.view_messages(child) })
  let log_messages = conversation_log.typed_view_messages(log: context.log)
  list.flatten([system_messages, child_messages, log_messages])
}

/// Compose tool definitions from all widgets.
pub fn view_tools(context context: Context) -> List(ToolDefinition) {
  let widget_tools =
    [context.system_prompt]
    |> list.append(context.children)
    |> list.flat_map(fn(w) { widget.view_tools(w) })
  let log_tools = conversation_log.typed_view_tools(log: context.log)
  list.append(widget_tools, log_tools)
}

/// Record a user message in the conversation log.
pub fn add_user_message(context context: Context, text text: String) -> Context {
  let msg = conversation_log.UserMessageReceived(text: text)
  let new_log = conversation_log.send_msg(log: context.log, msg: msg)
  rebuild_tool_owners(Context(..context, log: new_log))
}

/// Record an LLM response in the conversation log.
pub fn add_response(
  context context: Context,
  response response: Message,
) -> Context {
  let owning_task_id = conversation_log.owning_task_id(log: context.log)
  let msg =
    conversation_log.ResponseReceived(
      response: response,
      owning_task_id: owning_task_id,
    )
  let new_log = conversation_log.send_msg(log: context.log, msg: msg)
  rebuild_tool_owners(Context(..context, log: new_log))
}

/// Record tool results in the conversation log.
pub fn add_tool_results(
  context context: Context,
  request request: Message,
) -> Context {
  let owning_task_id = conversation_log.owning_task_id(log: context.log)
  let msg =
    conversation_log.ToolResultsReceived(
      request: request,
      owning_task_id: owning_task_id,
    )
  let new_log = conversation_log.send_msg(log: context.log, msg: msg)
  rebuild_tool_owners(Context(..context, log: new_log))
}

/// Consume picks from the conversation log (call after composing messages).
pub fn consume_picks(context context: Context) -> Context {
  let new_log =
    conversation_log.send_msg(
      log: context.log,
      msg: conversation_log.ConsumePicks,
    )
  Context(..context, log: new_log)
}

/// Handle an LLM tool call. Enforces the task protocol, then dispatches
/// to the owning widget.
///
/// Returns the updated context and either Ok(tool_result) or Error(error_message).
pub fn handle_tool_call(
  context context: Context,
  tool_name tool_name: String,
  args args: Dynamic,
  tool_call_id tool_call_id: String,
) -> #(Context, Result(String, String)) {
  // Check protocol first — conversation_log enforces task rules
  case
    conversation_log.protocol_check(
      log: context.log,
      tool_name: tool_name,
      protocol_free_tools: context.all_protocol_free_tools,
    )
  {
    Some(error_msg) -> #(context, Error(error_msg))
    None ->
      do_handle_tool_call(
        context: context,
        tool_name: tool_name,
        args: args,
        tool_call_id: tool_call_id,
      )
  }
}

/// Handle a browser UI event. Dispatches to all widgets that have the
/// event registered as a frontend tool. No protocol enforcement.
pub fn handle_widget_event(
  context context: Context,
  event_name event_name: String,
  args args: Dynamic,
) -> Context {
  // Try system_prompt
  let #(new_sp, _) =
    widget.dispatch_ui(
      handle: context.system_prompt,
      event_name: event_name,
      args: args,
    )

  // Try children
  let new_children =
    list.map(context.children, fn(child) {
      let #(new_child, _) =
        widget.dispatch_ui(handle: child, event_name: event_name, args: args)
      new_child
    })

  // Try conversation_log
  let #(new_log, _) =
    conversation_log.dispatch_event(
      log: context.log,
      event_name: event_name,
      args: args,
    )

  rebuild_tool_owners(
    Context(
      ..context,
      system_prompt: new_sp,
      children: new_children,
      log: new_log,
    ),
  )
}

/// Detect which widgets changed their HTML between two context snapshots.
/// Returns a list of (widget_id, new_html) pairs for widgets whose HTML differs.
pub fn changed_html(
  old old: Context,
  new new: Context,
) -> List(#(String, Element(Nil))) {
  let old_entries = all_widget_html_entries(old)
  let new_entries = all_widget_html_entries(new)

  list.zip(old_entries, new_entries)
  |> list.filter_map(fn(pair) {
    let #(old_entry, new_entry) = pair
    case old_entry.html_string == new_entry.html_string {
      True -> Error(Nil)
      False -> Ok(#(new_entry.id, new_entry.element))
    }
  })
}

/// Get the system_prompt widget handle.
pub fn system_prompt(context context: Context) -> WidgetHandle {
  context.system_prompt
}

/// Get the children widget handles.
pub fn children(context context: Context) -> List(WidgetHandle) {
  context.children
}

/// Get the typed conversation log.
pub fn log(context context: Context) -> ConversationLog {
  context.log
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Internal record for tracking widget HTML and its string representation.
type HtmlEntry {
  HtmlEntry(id: String, element: Element(Nil), html_string: String)
}

/// Collect HTML entries for all widgets in order.
fn all_widget_html_entries(context: Context) -> List(HtmlEntry) {
  let sp_element = widget.view_html(context.system_prompt)
  let sp_entry =
    HtmlEntry(
      id: widget.id(context.system_prompt),
      element: sp_element,
      html_string: element.to_string(sp_element),
    )

  let child_entries =
    list.map(context.children, fn(child) {
      let child_element = widget.view_html(child)
      HtmlEntry(
        id: widget.id(child),
        element: child_element,
        html_string: element.to_string(child_element),
      )
    })

  let log_element = conversation_log.typed_view_html(log: context.log)
  let log_entry =
    HtmlEntry(
      id: "conversation_log",
      element: log_element,
      html_string: element.to_string(log_element),
    )

  [sp_entry]
  |> list.append(child_entries)
  |> list.append([log_entry])
}

/// Rebuild the tool_owners map by scanning all widgets' current tools.
/// Also collects all protocol_free_tools from all widgets.
fn rebuild_tool_owners(context: Context) -> Context {
  let handle_widgets =
    [context.system_prompt]
    |> list.append(context.children)

  // Collect tool owners from handle-based widgets
  let tool_owners =
    list.fold(handle_widgets, dict.new(), fn(owners, w) {
      let widget_id = widget.id(w)
      let tools = widget.view_tools(w)
      list.fold(tools, owners, fn(acc, t) {
        dict.insert(acc, t.name, widget_id)
      })
    })

  // Add conversation_log tools
  let log_tools = conversation_log.typed_view_tools(log: context.log)
  let tool_owners =
    list.fold(log_tools, tool_owners, fn(acc, t) {
      dict.insert(acc, t.name, "conversation_log")
    })

  // Conversation log tools are always registered even when conditionally
  // hidden, so the owner can be found during dispatch regardless of state
  let tool_owners =
    list.fold(conversation_log_tool_names(), tool_owners, fn(acc, name) {
      dict.insert(acc, name, "conversation_log")
    })

  // Collect protocol_free_tools from all handle-based widgets
  let all_protocol_free =
    list.fold(handle_widgets, set.new(), fn(acc, w) {
      set.union(acc, widget.protocol_free_tools(w))
    })

  Context(
    ..context,
    tool_owners: tool_owners,
    all_protocol_free_tools: all_protocol_free,
  )
}

/// The conversation log tool names that are always registered for dispatch,
/// even when the tool definitions are conditionally hidden from view_tools.
fn conversation_log_tool_names() -> List(String) {
  [
    "create_task", "start_task", "task_memory", "close_current_task",
    "task_pick", "remove_task",
  ]
}

/// Dispatch a tool call to its owning widget after protocol check passed.
fn do_handle_tool_call(
  context context: Context,
  tool_name tool_name: String,
  args args: Dynamic,
  tool_call_id _tool_call_id: String,
) -> #(Context, Result(String, String)) {
  case dict.get(context.tool_owners, tool_name) {
    Error(Nil) -> #(context, Error("Unknown tool: " <> tool_name))
    Ok(owner_id) ->
      dispatch_to_owner(
        context: context,
        owner_id: owner_id,
        tool_name: tool_name,
        args: args,
      )
  }
}

/// Find the owning widget and dispatch the tool call to it.
fn dispatch_to_owner(
  context context: Context,
  owner_id owner_id: String,
  tool_name tool_name: String,
  args args: Dynamic,
) -> #(Context, Result(String, String)) {
  case owner_id {
    "conversation_log" -> {
      let #(new_log, result) =
        conversation_log.dispatch_tool(
          log: context.log,
          tool_name: tool_name,
          args: args,
        )
      let ctx = rebuild_tool_owners(Context(..context, log: new_log))
      #(ctx, result)
    }
    _ -> dispatch_to_handle_widget(context:, owner_id:, tool_name:, args:)
  }
}

/// Dispatch to a handle-based widget (system_prompt or children).
fn dispatch_to_handle_widget(
  context context: Context,
  owner_id owner_id: String,
  tool_name tool_name: String,
  args args: Dynamic,
) -> #(Context, Result(String, String)) {
  // Try system_prompt
  case widget.id(context.system_prompt) == owner_id {
    True -> {
      let #(new_sp, result) =
        widget.dispatch_llm(
          handle: context.system_prompt,
          tool_name: tool_name,
          args: args,
        )
      let ctx = rebuild_tool_owners(Context(..context, system_prompt: new_sp))
      #(ctx, result)
    }
    False ->
      // Try children
      case
        find_and_dispatch_child(
          remaining: context.children,
          owner_id: owner_id,
          tool_name: tool_name,
          args: args,
          before: [],
        )
      {
        Ok(#(new_children, result)) -> {
          let ctx =
            rebuild_tool_owners(Context(..context, children: new_children))
          #(ctx, result)
        }
        Error(Nil) -> #(context, Error("Unknown tool: " <> tool_name))
      }
  }
}

/// Find the child with the given owner_id and dispatch the tool call.
/// Returns the updated children list, or Error if the owner was not found.
fn find_and_dispatch_child(
  remaining remaining: List(WidgetHandle),
  owner_id owner_id: String,
  tool_name tool_name: String,
  args args: Dynamic,
  before before: List(WidgetHandle),
) -> Result(#(List(WidgetHandle), Result(String, String)), Nil) {
  case remaining {
    [] -> Error(Nil)
    [child, ..rest] ->
      case widget.id(child) == owner_id {
        True -> {
          let #(new_child, result) =
            widget.dispatch_llm(handle: child, tool_name: tool_name, args: args)
          let new_children =
            list.reverse(before)
            |> list.append([new_child])
            |> list.append(rest)
          Ok(#(new_children, result))
        }
        False ->
          find_and_dispatch_child(
            remaining: rest,
            owner_id: owner_id,
            tool_name: tool_name,
            args: args,
            before: [child, ..before],
          )
      }
  }
}
