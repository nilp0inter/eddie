/// ConversationLog widget — task-partitioned conversation history.
///
/// The conversation is partitioned by **tasks**. Each log item belongs either
/// to no task or to a specific task. A task is a unit of work with status
/// `Pending -> InProgress -> Done`. At most one task can be `InProgress`
/// at any time.
///
/// While a task is `InProgress`, all messages are tagged with its id.
/// When the LLM closes the task, the full span is collapsed for future
/// prompts: only the task description and the LLM-authored **memories**
/// survive. The browser can still expand the span visually, and the LLM
/// can request one-shot re-expansion via `task_pick(task_id)`.
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd.{type Cmd, type Initiator, CmdNone, LLM, UI}
import eddie/message.{type Message}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}

// ============================================================================
// Supporting types
// ============================================================================

pub type TaskStatus {
  Pending
  InProgress
  Done
}

pub type Task {
  Task(
    id: Int,
    description: String,
    status: TaskStatus,
    memories: List(String),
    ui_expanded: Bool,
  )
}

/// One chronological log entry. Exactly one payload variant.
pub type LogItem {
  UserMessageItem(text: String, owning_task_id: Option(Int))
  ResponseItem(response: Message, owning_task_id: Option(Int))
  ToolResultsItem(request: Message, owning_task_id: Option(Int))
}

// ============================================================================
// Model
// ============================================================================

pub type ConversationLogModel {
  ConversationLogModel(
    /// Chronological log — newest first (prepend). Reverse when viewing.
    log: List(LogItem),
    tasks: Dict(Int, Task),
    /// Task creation order — newest first (prepend). Reverse when viewing.
    task_order: List(Int),
    next_id: Int,
    active_task_id: Option(Int),
    picks_for_next_request: Set(Int),
  )
}

/// Create an empty tasks dict. Exposed for testing protocol checks.
pub fn new_empty_tasks() -> Dict(Int, Task) {
  dict.new()
}

fn new_model() -> ConversationLogModel {
  ConversationLogModel(
    log: [],
    tasks: dict.new(),
    task_order: [],
    next_id: 1,
    active_task_id: None,
    picks_for_next_request: set.new(),
  )
}

// ============================================================================
// Messages
// ============================================================================

pub type ConversationLogMsg {
  // Task management (LLM or UI)
  CreateTask(description: String, initiator: Initiator)
  StartTask(task_id: Int, initiator: Initiator)
  TaskMemoryAppend(
    text: String,
    target_task_id: Option(Int),
    initiator: Initiator,
  )
  CloseCurrentTask(initiator: Initiator)
  PickTask(task_id: Int, initiator: Initiator)
  RemoveTask(task_id: Int, initiator: Initiator)
  // UI only
  EditMemory(task_id: Int, index: Int, new_text: String)
  RemoveMemory(task_id: Int, index: Int)
  ToggleTaskExpanded(task_id: Int)
  UpdateTaskStatus(task_id: Int, status: TaskStatus, initiator: Initiator)
  // Internal (sent via .send())
  UserMessageReceived(text: String)
  ResponseReceived(response: Message, owning_task_id: Option(Int))
  ToolResultsReceived(request: Message, owning_task_id: Option(Int))
  ConsumePicks
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: ConversationLogModel,
  msg: ConversationLogMsg,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case msg {
    CreateTask(description, initiator) ->
      update_create_task(model: model, description:, initiator:)
    StartTask(task_id, initiator) ->
      update_start_task(model: model, task_id:, initiator:)
    TaskMemoryAppend(text, target, initiator) ->
      update_task_memory(model: model, text:, target:, initiator:)
    CloseCurrentTask(initiator) -> update_close_task(model: model, initiator:)
    PickTask(task_id, initiator) ->
      update_pick_task(model: model, task_id:, initiator:)
    RemoveTask(task_id, initiator) ->
      update_remove_task(model: model, task_id:, initiator:)
    EditMemory(task_id, index, new_text) ->
      update_edit_memory(model: model, task_id:, index:, new_text:)
    RemoveMemory(task_id, index) ->
      update_remove_memory(model: model, task_id:, index:)
    ToggleTaskExpanded(task_id) ->
      update_toggle_expanded(model: model, task_id:)
    UpdateTaskStatus(task_id, status, initiator) ->
      update_task_status(model: model, task_id:, status:, initiator:)
    UserMessageReceived(text) -> {
      let item =
        UserMessageItem(text: text, owning_task_id: model.active_task_id)
      #(ConversationLogModel(..model, log: [item, ..model.log]), CmdNone)
    }
    ResponseReceived(response, owning_task_id) -> {
      let item =
        ResponseItem(response: response, owning_task_id: owning_task_id)
      #(ConversationLogModel(..model, log: [item, ..model.log]), CmdNone)
    }
    ToolResultsReceived(request, owning_task_id) -> {
      let item =
        ToolResultsItem(request: request, owning_task_id: owning_task_id)
      #(ConversationLogModel(..model, log: [item, ..model.log]), CmdNone)
    }
    ConsumePicks -> #(
      ConversationLogModel(..model, picks_for_next_request: set.new()),
      CmdNone,
    )
  }
}

fn update_create_task(
  model model: ConversationLogModel,
  description description: String,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  let task_id = model.next_id
  let task =
    Task(
      id: task_id,
      description: description,
      status: Pending,
      memories: [],
      ui_expanded: False,
    )
  let new_model =
    ConversationLogModel(
      ..model,
      tasks: dict.insert(model.tasks, task_id, task),
      task_order: [task_id, ..model.task_order],
      next_id: task_id + 1,
    )
  let text = "Created task " <> int.to_string(task_id) <> ": " <> description
  #(new_model, cmd.for_initiator(initiator:, text:))
}

fn update_start_task(
  model model: ConversationLogModel,
  task_id task_id: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case model.active_task_id {
    Some(active_id) -> {
      let text =
        "Cannot start task "
        <> int.to_string(task_id)
        <> ": task "
        <> int.to_string(active_id)
        <> " is already in_progress. Call close_current_task first."
      #(model, cmd.for_initiator(initiator:, text:))
    }
    None -> do_start_task(model:, task_id:, initiator:)
  }
}

fn do_start_task(
  model model: ConversationLogModel,
  task_id task_id: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id:, initiator:))
    Ok(task) ->
      case task.status {
        Pending -> {
          let updated_task = Task(..task, status: InProgress)
          let new_model =
            ConversationLogModel(
              ..model,
              tasks: dict.insert(model.tasks, task_id, updated_task),
              active_task_id: Some(task_id),
            )
          let text =
            "Started task "
            <> int.to_string(task_id)
            <> ": "
            <> task.description
          #(new_model, cmd.for_initiator(initiator:, text:))
        }
        _ -> {
          let text =
            "Task "
            <> int.to_string(task_id)
            <> " cannot be started: status is "
            <> status_to_string(task.status)
            <> " (only pending tasks can be started)."
          #(model, cmd.for_initiator(initiator:, text:))
        }
      }
  }
}

fn update_task_memory(
  model model: ConversationLogModel,
  text text: String,
  target target: Option(Int),
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  // LLM always targets the active task (target is None).
  // UI may target any task directly.
  let resolved_target = option.or(target, model.active_task_id)
  case resolved_target {
    None -> {
      let err = "Cannot append memory: no active task."
      #(model, cmd.for_initiator(initiator:, text: err))
    }
    Some(tid) -> do_task_memory_append(model:, text:, tid:, initiator:)
  }
}

fn do_task_memory_append(
  model model: ConversationLogModel,
  text text: String,
  tid tid: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, tid) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id: tid, initiator:))
    Ok(task) ->
      // LLM can only append to the current in_progress task
      case initiator, task.status {
        LLM, InProgress | UI, _ -> {
          // Prepend memory (reversed when viewing)
          let updated_task = Task(..task, memories: [text, ..task.memories])
          let new_model =
            ConversationLogModel(
              ..model,
              tasks: dict.insert(model.tasks, tid, updated_task),
            )
          let result_text =
            "Memory recorded on task " <> int.to_string(tid) <> "."
          #(new_model, cmd.for_initiator(initiator:, text: result_text))
        }
        LLM, _ -> {
          let err =
            "Cannot append memory to task "
            <> int.to_string(tid)
            <> ": memories are frozen for the LLM once a task is closed. Only the currently in_progress task can receive new memories from the LLM."
          #(model, cmd.for_initiator(initiator:, text: err))
        }
      }
  }
}

fn update_close_task(
  model model: ConversationLogModel,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case model.active_task_id {
    None -> {
      let err = "No task is in_progress."
      #(model, cmd.for_initiator(initiator:, text: err))
    }
    Some(tid) -> do_close_task(model:, tid:, initiator:)
  }
}

fn do_close_task(
  model model: ConversationLogModel,
  tid tid: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, tid) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id: tid, initiator:))
    Ok(task) ->
      case task.memories {
        [] -> {
          let err =
            "Cannot close the current task without any memory. Call task_memory(...) first, recording anything you need to remember — once the task is closed you cannot add more."
          #(model, cmd.for_initiator(initiator:, text: err))
        }
        _ -> {
          let updated_task = Task(..task, status: Done)
          let new_model =
            ConversationLogModel(
              ..model,
              tasks: dict.insert(model.tasks, tid, updated_task),
              active_task_id: None,
            )
          let text = "Closed task " <> int.to_string(tid) <> "."
          #(new_model, cmd.for_initiator(initiator:, text:))
        }
      }
  }
}

fn update_pick_task(
  model model: ConversationLogModel,
  task_id task_id: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id:, initiator:))
    Ok(task) ->
      case task.status {
        Done -> {
          let new_model =
            ConversationLogModel(
              ..model,
              picks_for_next_request: set.insert(
                model.picks_for_next_request,
                task_id,
              ),
            )
          let text =
            "Task "
            <> int.to_string(task_id)
            <> " will be expanded for the next request only."
          #(new_model, cmd.for_initiator(initiator:, text:))
        }
        _ -> {
          let err =
            "Task "
            <> int.to_string(task_id)
            <> " is not done (status: "
            <> status_to_string(task.status)
            <> "). Only done tasks can be picked for expansion."
          #(model, cmd.for_initiator(initiator:, text: err))
        }
      }
  }
}

fn update_remove_task(
  model model: ConversationLogModel,
  task_id task_id: Int,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id:, initiator:))
    Ok(task) ->
      case task.status {
        Pending -> {
          let new_model =
            ConversationLogModel(
              ..model,
              tasks: dict.delete(model.tasks, task_id),
              task_order: list.filter(model.task_order, fn(id) { id != task_id }),
            )
          let text = "Removed task " <> int.to_string(task_id) <> "."
          #(new_model, cmd.for_initiator(initiator:, text:))
        }
        _ -> {
          let err =
            "Cannot remove task "
            <> int.to_string(task_id)
            <> ": only pending tasks can be removed. In-progress and done tasks are frozen."
          #(model, cmd.for_initiator(initiator:, text: err))
        }
      }
  }
}

fn update_edit_memory(
  model model: ConversationLogModel,
  task_id task_id: Int,
  index index: Int,
  new_text new_text: String,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, CmdNone)
    Ok(task) -> do_edit_memory(model:, task_id:, task:, index:, new_text:)
  }
}

fn do_edit_memory(
  model model: ConversationLogModel,
  task_id task_id: Int,
  task task: Task,
  index index: Int,
  new_text new_text: String,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  // Memories stored reversed (newest first); map user-facing to internal
  let mem_len = list.length(task.memories)
  let internal_index = mem_len - 1 - index
  case internal_index >= 0 && internal_index < mem_len {
    False -> #(model, CmdNone)
    True -> {
      let updated_memories =
        list.index_map(task.memories, fn(mem, i) {
          case i == internal_index {
            True -> new_text
            False -> mem
          }
        })
      let updated_task = Task(..task, memories: updated_memories)
      #(set_task(model:, task_id:, task: updated_task), CmdNone)
    }
  }
}

fn update_remove_memory(
  model model: ConversationLogModel,
  task_id task_id: Int,
  index index: Int,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, CmdNone)
    Ok(task) -> do_remove_memory(model:, task_id:, task:, index:)
  }
}

fn do_remove_memory(
  model model: ConversationLogModel,
  task_id task_id: Int,
  task task: Task,
  index index: Int,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  let mem_len = list.length(task.memories)
  let internal_index = mem_len - 1 - index
  case internal_index >= 0 && internal_index < mem_len {
    False -> #(model, CmdNone)
    True -> {
      let updated_memories =
        list.index_map(task.memories, fn(mem, i) { #(i, mem) })
        |> list.filter(fn(pair) { pair.0 != internal_index })
        |> list.map(fn(pair) { pair.1 })
      let updated_task = Task(..task, memories: updated_memories)
      #(set_task(model:, task_id:, task: updated_task), CmdNone)
    }
  }
}

fn update_toggle_expanded(
  model model: ConversationLogModel,
  task_id task_id: Int,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, CmdNone)
    Ok(task) -> {
      let updated_task = Task(..task, ui_expanded: !task.ui_expanded)
      #(set_task(model:, task_id:, task: updated_task), CmdNone)
    }
  }
}

fn update_task_status(
  model model: ConversationLogModel,
  task_id task_id: Int,
  status status: TaskStatus,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> #(model, task_not_found_cmd(task_id:, initiator:))
    Ok(task) -> do_update_task_status(model:, task:, status:, initiator:)
  }
}

fn do_update_task_status(
  model model: ConversationLogModel,
  task task: Task,
  status status: TaskStatus,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  // Transitions into InProgress go through start logic
  case status {
    InProgress ->
      case task.status {
        InProgress -> {
          let text =
            "Task " <> int.to_string(task.id) <> " already in_progress."
          #(model, cmd.for_initiator(initiator:, text:))
        }
        _ -> update(model, StartTask(task_id: task.id, initiator: initiator))
      }
    _ -> do_update_task_status_non_progress(model:, task:, status:, initiator:)
  }
}

fn do_update_task_status_non_progress(
  model model: ConversationLogModel,
  task task: Task,
  status status: TaskStatus,
  initiator initiator: Initiator,
) -> #(ConversationLogModel, Cmd(ConversationLogMsg)) {
  case task.status {
    // Moving out of InProgress requires memories
    InProgress ->
      case task.memories {
        [] -> {
          let err =
            "Cannot move task "
            <> int.to_string(task.id)
            <> " out of in_progress without at least one memory. Add a memory first."
          #(model, cmd.for_initiator(initiator:, text: err))
        }
        _ -> {
          let updated_task = Task(..task, status: status)
          let new_model =
            ConversationLogModel(
              ..set_task(model:, task_id: task.id, task: updated_task),
              active_task_id: None,
            )
          let text = task_status_change_text(task.id, status)
          #(new_model, cmd.for_initiator(initiator:, text:))
        }
      }
    _ -> {
      let updated_task = Task(..task, status: status)
      let new_model = set_task(model:, task_id: task.id, task: updated_task)
      let text = task_status_change_text(task.id, status)
      #(new_model, cmd.for_initiator(initiator:, text:))
    }
  }
}

// ============================================================================
// Protocol checking
// ============================================================================

/// Check if a tool call is allowed under the task protocol.
/// Returns Some(error_message) if the call violates the protocol,
/// or None if it's allowed.
pub fn check_protocol(
  model model: ConversationLogModel,
  tool_name tool_name: String,
  protocol_free_tools protocol_free_tools: Set(String),
) -> Option(String) {
  case tool_name {
    // Task management tools — always callable
    "create_task" | "task_pick" | "remove_task" -> None
    "start_task" ->
      case model.active_task_id {
        Some(active_id) ->
          Some(
            "Cannot start a task while task "
            <> int.to_string(active_id)
            <> " is in_progress. Call close_current_task first.",
          )
        None -> None
      }
    "close_current_task" -> check_protocol_close(model)
    "task_memory" ->
      case model.active_task_id {
        None ->
          Some(
            "Cannot append memory outside a task. Start a task first with start_task(task_id).",
          )
        Some(_) -> None
      }
    // Any other tool — allowed iff a task is active or tool is protocol-free
    _ ->
      case model.active_task_id {
        Some(_) -> None
        None ->
          case set.contains(protocol_free_tools, tool_name) {
            True -> None
            False ->
              Some(
                "Cannot execute '"
                <> tool_name
                <> "' outside a task. Start a task first with start_task(task_id).",
              )
          }
      }
  }
}

fn check_protocol_close(model: ConversationLogModel) -> Option(String) {
  case model.active_task_id {
    None -> Some("No task is in_progress; nothing to close.")
    Some(tid) -> {
      let has_memories =
        dict.get(model.tasks, tid)
        |> result.map(fn(task) { task.memories != [] })
        |> result.unwrap(False)
      case has_memories {
        True -> None
        False ->
          Some(
            "Cannot close the current task without at least one memory. Call task_memory(...) first, recording anything you need to remember — once the task is closed you cannot add more.",
          )
      }
    }
  }
}

/// Return the active task id (the task that will own newly arriving log items).
pub fn current_owning_task_id(model model: ConversationLogModel) -> Option(Int) {
  model.active_task_id
}

// ============================================================================
// Tool definitions
// ============================================================================

fn make_tool(
  name name: String,
  description description: String,
  parameters_json parameters_json: json.Json,
) -> ToolDefinition {
  // tool.new only fails on malformed JSON; our literals are always valid
  let assert Ok(td) = tool.new(name:, description:, parameters_json:)
  td
}

fn task_id_schema() -> #(String, json.Json) {
  #(
    "task_id",
    json.object([
      #("type", json.string("integer")),
      #("description", json.string("The task ID.")),
    ]),
  )
}

fn tool_create_task() -> ToolDefinition {
  make_tool(
    name: "create_task",
    description: "Create a new pending task with the given description. Does not start the task — call start_task(task_id) afterwards to begin working on it.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "description",
            json.object([
              #("type", json.string("string")),
              #("description", json.string("The task description.")),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["description"], json.string)),
    ]),
  )
}

fn tool_start_task() -> ToolDefinition {
  make_tool(
    name: "start_task",
    description: "Mark a pending task as in_progress. Only one task can be in_progress at a time. While in_progress, all your conversation is recorded against this task; on close, it collapses to the memory list you saved.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #("properties", json.object([task_id_schema()])),
      #("required", json.array(["task_id"], json.string)),
    ]),
  )
}

fn tool_task_memory() -> ToolDefinition {
  make_tool(
    name: "task_memory",
    description: "Record a memory on the current in_progress task. Call this AGGRESSIVELY during a task — anything relevant to the overall goal, any surprising finding, any decision, any key file path or API shape. Memories are your ONLY durable record of the task. After close, you cannot add more.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "text",
            json.object([
              #("type", json.string("string")),
              #(
                "description",
                json.string(
                  "The memory to record. Be concrete. Be complete. Assume the tool-call transcript will be erased.",
                ),
              ),
            ]),
          ),
        ]),
      ),
      #("required", json.array(["text"], json.string)),
    ]),
  )
}

fn tool_close_current_task() -> ToolDefinition {
  make_tool(
    name: "close_current_task",
    description: "Close the in_progress task. Must be the FIRST AND ONLY tool call in its response. Requires at least one memory recorded on the task. After close, the task's conversation collapses to the memory list — the raw tool calls/results are no longer visible to you. Only call this once you have recorded every memory you need.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #("properties", json.object([])),
    ]),
  )
}

fn tool_task_pick() -> ToolDefinition {
  make_tool(
    name: "task_pick",
    description: "Expand the full log of a done task for the NEXT REQUEST ONLY. On the request after next, the task collapses again to its memory block. Use this when the memories don't cover something you now need from that task.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #("properties", json.object([task_id_schema()])),
      #("required", json.array(["task_id"], json.string)),
    ]),
  )
}

fn tool_remove_task() -> ToolDefinition {
  make_tool(
    name: "remove_task",
    description: "Remove a pending task. Only pending tasks can be removed — in-progress and done tasks are frozen.",
    parameters_json: json.object([
      #("type", json.string("object")),
      #("properties", json.object([task_id_schema()])),
      #("required", json.array(["task_id"], json.string)),
    ]),
  )
}

fn view_tools(model: ConversationLogModel) -> List(ToolDefinition) {
  let has_pending =
    dict.values(model.tasks)
    |> list.any(fn(t) { t.status == Pending })
  let has_done =
    dict.values(model.tasks)
    |> list.any(fn(t) { t.status == Done })

  // Always available
  let tools = [tool_create_task()]

  // remove_task — only if any pending tasks exist
  let tools = case has_pending {
    True -> [tool_remove_task(), ..tools]
    False -> tools
  }

  // task_pick — only if any done tasks exist
  let tools = case has_done {
    True -> [tool_task_pick(), ..tools]
    False -> tools
  }

  case model.active_task_id {
    None ->
      case has_pending {
        True -> [tool_start_task(), ..tools]
        False -> tools
      }
    Some(tid) -> {
      let tools = [tool_task_memory(), ..tools]
      case dict.get(model.tasks, tid) {
        Ok(task) ->
          case task.memories {
            [] -> tools
            _ -> [tool_close_current_task(), ..tools]
          }
        Error(Nil) -> tools
      }
    }
  }
  |> list.reverse
}

// ============================================================================
// View messages — grouped by owning_task_id with collapsing
// ============================================================================

fn view_messages(model: ConversationLogModel) -> List(Message) {
  let protocol_msg =
    message.Request(parts: [message.SystemPart(task_protocol_rules)])

  // Walk log in chronological order (reversed from internal prepend order)
  let log = list.reverse(model.log)
  let grouped_messages = view_log_groups(log: log, model: model)

  // Open tasks block
  let task_order = list.reverse(model.task_order)
  let open_tasks =
    list.filter_map(task_order, fn(tid) {
      case dict.get(model.tasks, tid) {
        Ok(task) ->
          case task.status {
            Pending | InProgress -> Ok(task)
            Done -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })
  let open_tasks_messages = case open_tasks {
    [] -> []
    _ -> {
      let lines =
        ["## Open tasks"]
        |> list.append(
          list.map(open_tasks, fn(task) {
            status_icon(task.status)
            <> " "
            <> int.to_string(task.id)
            <> ". "
            <> task.description
          }),
        )
      [message.Request(parts: [message.UserPart(string.join(lines, "\n"))])]
    }
  }

  [protocol_msg]
  |> list.append(grouped_messages)
  |> list.append(open_tasks_messages)
}

/// Walk the log grouping consecutive items by owning_task_id
fn view_log_groups(
  log log: List(LogItem),
  model model: ConversationLogModel,
) -> List(Message) {
  case log {
    [] -> []
    [first, ..] -> {
      let group_tid = log_item_task_id(first)
      let #(group, rest) = take_group(log: log, tid: group_tid, accumulator: [])
      let group_messages =
        render_group(group: group, tid: group_tid, model: model)
      list.append(group_messages, view_log_groups(log: rest, model: model))
    }
  }
}

/// Take consecutive items with the same owning_task_id
fn take_group(
  log log: List(LogItem),
  tid tid: Option(Int),
  accumulator accumulator: List(LogItem),
) -> #(List(LogItem), List(LogItem)) {
  case log {
    [] -> #(list.reverse(accumulator), [])
    [item, ..rest] ->
      case log_item_task_id(item) == tid {
        True ->
          take_group(log: rest, tid: tid, accumulator: [item, ..accumulator])
        False -> #(list.reverse(accumulator), log)
      }
  }
}

/// Render a group of log items with the same owning_task_id
fn render_group(
  group group: List(LogItem),
  tid tid: Option(Int),
  model model: ConversationLogModel,
) -> List(Message) {
  case tid {
    None -> yield_raw(group)
    Some(task_id) -> render_task_group(group:, task_id:, model:)
  }
}

fn render_task_group(
  group group: List(LogItem),
  task_id task_id: Int,
  model model: ConversationLogModel,
) -> List(Message) {
  case dict.get(model.tasks, task_id) {
    Error(Nil) -> yield_raw(group)
    Ok(task) ->
      case task.status {
        InProgress -> yield_raw(group)
        _ -> {
          // Done (or Pending — defensive)
          let picked = set.contains(model.picks_for_next_request, task_id)
          let collapsed =
            message.Request(parts: [
              message.SystemPart(format_collapsed_block(task, picked)),
            ])
          case picked {
            True -> [collapsed, ..yield_raw(group)]
            False -> [collapsed]
          }
        }
      }
  }
}

fn yield_raw(group: List(LogItem)) -> List(Message) {
  list.filter_map(group, fn(item) {
    case item {
      UserMessageItem(text, _) ->
        Ok(message.Request(parts: [message.UserPart(text)]))
      ResponseItem(response, _) -> Ok(response)
      ToolResultsItem(request, _) -> Ok(request)
    }
  })
}

fn format_collapsed_block(task: Task, picked: Bool) -> String {
  let header = [
    "# Task: " <> task.description,
    "## Task ID: " <> int.to_string(task.id),
    "## Task summary",
  ]
  // Memories stored reversed — display in original order
  let memories = list.reverse(task.memories)
  let memory_lines = case memories {
    [] -> ["_(no memories recorded)_"]
    _ ->
      list.index_map(memories, fn(mem, i) {
        "### Memory " <> int.to_string(i + 1) <> "\n" <> mem
      })
  }
  let note = case picked {
    True ->
      "## Notes: You are viewing this task's full log for this request only; it collapses again on the next request."
    False ->
      "## Notes: This is a collapsed representation of an already finished task. The details are not shown. If you need temporary access to this task's details, please execute task_pick(task_id="
      <> int.to_string(task.id)
      <> ")."
  }
  string.join(list.flatten([header, memory_lines, [""], [note]]), "\n")
}

fn log_item_task_id(item: LogItem) -> Option(Int) {
  case item {
    UserMessageItem(_, tid) -> tid
    ResponseItem(_, tid) -> tid
    ToolResultsItem(_, tid) -> tid
  }
}

// ============================================================================
// View HTML (placeholder — will be fleshed out in Phase 4)
// ============================================================================

fn view_html(model: ConversationLogModel) -> Element(Nil) {
  let task_count = dict.size(model.tasks)
  let log_count = list.length(model.log)
  html.div([], [
    html.text(
      "Conversation Log: "
      <> int.to_string(log_count)
      <> " items, "
      <> int.to_string(task_count)
      <> " tasks",
    ),
  ])
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: ConversationLogModel,
  tool_name: String,
  args: Dynamic,
) -> Result(ConversationLogMsg, String) {
  case tool_name {
    "create_task" ->
      decode_field_string(args, "description", fn(desc) {
        CreateTask(description: desc, initiator: LLM)
      })
    "start_task" ->
      decode_field_int(args, "task_id", fn(tid) {
        StartTask(task_id: tid, initiator: LLM)
      })
    "task_memory" ->
      decode_field_string(args, "text", fn(text) {
        TaskMemoryAppend(text: text, target_task_id: None, initiator: LLM)
      })
    "close_current_task" -> Ok(CloseCurrentTask(initiator: LLM))
    "task_pick" ->
      decode_field_int(args, "task_id", fn(tid) {
        PickTask(task_id: tid, initiator: LLM)
      })
    "remove_task" ->
      decode_field_int(args, "task_id", fn(tid) {
        RemoveTask(task_id: tid, initiator: LLM)
      })
    _ -> Error("ConversationLog: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: ConversationLogModel,
  event_name: String,
  args: Dynamic,
) -> Option(ConversationLogMsg) {
  case event_name {
    "create_task" -> from_ui_create_task(args)
    "start_task" ->
      decode_ui_int(args, "task_id", fn(tid) {
        StartTask(task_id: tid, initiator: UI)
      })
    "task_memory" -> from_ui_task_memory(args)
    "close_current_task" -> Some(CloseCurrentTask(initiator: UI))
    "task_pick" ->
      decode_ui_int(args, "task_id", fn(tid) {
        PickTask(task_id: tid, initiator: UI)
      })
    "remove_task" ->
      decode_ui_int(args, "task_id", fn(tid) {
        RemoveTask(task_id: tid, initiator: UI)
      })
    "edit_memory" -> from_ui_edit_memory(args)
    "remove_memory" -> from_ui_remove_memory(args)
    "toggle_task_expanded" ->
      decode_ui_int(args, "task_id", fn(tid) {
        ToggleTaskExpanded(task_id: tid)
      })
    "update_task_status" -> from_ui_update_task_status(args)
    _ -> None
  }
}

fn from_ui_create_task(args: Dynamic) -> Option(ConversationLogMsg) {
  case decode.run(args, decode.at(["description"], decode.string)) {
    Ok(description) ->
      case string.trim(description) {
        "" -> None
        trimmed -> Some(CreateTask(description: trimmed, initiator: UI))
      }
    Error(_) -> None
  }
}

fn from_ui_task_memory(args: Dynamic) -> Option(ConversationLogMsg) {
  case decode.run(args, decode.at(["text"], decode.string)) {
    Ok(text) ->
      case string.trim(text) {
        "" -> None
        trimmed -> {
          let target =
            decode.run(
              args,
              decode.at(["task_id"], decode.optional(decode.int)),
            )
            |> result.unwrap(None)
          Some(TaskMemoryAppend(
            text: trimmed,
            target_task_id: target,
            initiator: UI,
          ))
        }
      }
    Error(_) -> None
  }
}

fn from_ui_edit_memory(args: Dynamic) -> Option(ConversationLogMsg) {
  let decoder = {
    use task_id <- decode.field("task_id", decode.int)
    use index <- decode.field("index", decode.int)
    use new_text <- decode.field("new_text", decode.string)
    decode.success(EditMemory(task_id:, index:, new_text:))
  }
  case decode.run(args, decoder) {
    Ok(msg) -> Some(msg)
    Error(_) -> None
  }
}

fn from_ui_remove_memory(args: Dynamic) -> Option(ConversationLogMsg) {
  let decoder = {
    use task_id <- decode.field("task_id", decode.int)
    use index <- decode.field("index", decode.int)
    decode.success(RemoveMemory(task_id:, index:))
  }
  case decode.run(args, decoder) {
    Ok(msg) -> Some(msg)
    Error(_) -> None
  }
}

fn from_ui_update_task_status(args: Dynamic) -> Option(ConversationLogMsg) {
  let decoder = {
    use task_id <- decode.field("task_id", decode.int)
    use status_str <- decode.field("status", decode.string)
    decode.success(#(task_id, status_str))
  }
  case decode.run(args, decoder) {
    Ok(#(task_id, status_str)) ->
      case parse_task_status(status_str) {
        Ok(status) -> Some(UpdateTaskStatus(task_id:, status:, initiator: UI))
        Error(Nil) -> None
      }
    Error(_) -> None
  }
}

// ============================================================================
// Factory
// ============================================================================

/// Create a ConversationLog widget handle.
pub fn create() -> WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "conversation_log",
    model: new_model(),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_html: view_html,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.from_list([
      "create_task", "start_task", "task_memory", "close_current_task",
      "task_pick", "remove_task", "edit_memory", "remove_memory",
      "toggle_task_expanded", "update_task_status",
    ]),
    protocol_free_tools: set.new(),
  ))
}

// ============================================================================
// Helpers
// ============================================================================

fn status_to_string(status: TaskStatus) -> String {
  case status {
    Pending -> "pending"
    InProgress -> "in_progress"
    Done -> "done"
  }
}

fn status_icon(status: TaskStatus) -> String {
  case status {
    Pending -> "[ ]"
    InProgress -> "[~]"
    Done -> "[x]"
  }
}

fn parse_task_status(s: String) -> Result(TaskStatus, Nil) {
  case s {
    "pending" -> Ok(Pending)
    "in_progress" -> Ok(InProgress)
    "done" -> Ok(Done)
    _ -> Error(Nil)
  }
}

fn task_not_found_cmd(
  task_id task_id: Int,
  initiator initiator: Initiator,
) -> Cmd(ConversationLogMsg) {
  let text = "Task " <> int.to_string(task_id) <> " not found"
  cmd.for_initiator(initiator:, text:)
}

fn task_status_change_text(task_id: Int, status: TaskStatus) -> String {
  "Task " <> int.to_string(task_id) <> " → " <> status_to_string(status) <> "."
}

fn set_task(
  model model: ConversationLogModel,
  task_id task_id: Int,
  task task: Task,
) -> ConversationLogModel {
  ConversationLogModel(..model, tasks: dict.insert(model.tasks, task_id, task))
}

/// Decode a string field from Dynamic, mapping to a message on success
fn decode_field_string(
  args: Dynamic,
  field_name: String,
  to_msg: fn(String) -> ConversationLogMsg,
) -> Result(ConversationLogMsg, String) {
  case decode.run(args, decode.at([field_name], decode.string)) {
    Ok(value) -> Ok(to_msg(value))
    Error(_) -> Error("Expected '" <> field_name <> "' string in arguments")
  }
}

/// Decode an int field from Dynamic, mapping to a message on success
fn decode_field_int(
  args: Dynamic,
  field_name: String,
  to_msg: fn(Int) -> ConversationLogMsg,
) -> Result(ConversationLogMsg, String) {
  case decode.run(args, decode.at([field_name], decode.int)) {
    Ok(value) -> Ok(to_msg(value))
    Error(_) -> Error("Expected '" <> field_name <> "' integer in arguments")
  }
}

/// Decode a UI int field, returning Option
fn decode_ui_int(
  args: Dynamic,
  field_name: String,
  to_msg: fn(Int) -> ConversationLogMsg,
) -> Option(ConversationLogMsg) {
  case decode.run(args, decode.at([field_name], decode.int)) {
    Ok(value) -> Some(to_msg(value))
    Error(_) -> None
  }
}

// ============================================================================
// Task protocol rules (shown to the LLM as a system prompt)
// ============================================================================

const task_protocol_rules = "## Task Protocol — conversation memory management

Your conversation is partitioned into **tasks**. Every tool call you make (except task management and goal management) must happen while a task is `in_progress`. When you close a task with `close_current_task`, the full span of that task — every tool call, every tool result, every intermediate response — is **replaced** for future prompts by the task's **memories**.

### Lifecycle
1. `create_task(description)` — plan a unit of work (or reuse a pending one).
2. `start_task(task_id)` — mark it `in_progress`. Only one task can be `in_progress` at a time.
3. Do the work — call any tools you need, freely interleaved.
4. `task_memory(text)` — **call this aggressively** to record anything you will need later: findings, file paths, API shapes, decisions, partial results, dead ends you already explored. Call it multiple times during the task. Memories are **APPEND-ONLY while the task is in_progress** — after close, you cannot add more.
5. `close_current_task()` — in a response by itself, as the first and only tool call. Requires at least one memory.

### MEMORIES ARE YOUR ONLY DURABLE RECORD
After `close_current_task`, the task's conversation becomes a collapsed block containing only the memories you saved. The raw tool calls, tool results, and your intermediate thinking are hidden from future prompts. You cannot undo this. **Save memories aggressively** — anything relevant to the overall goal, any non-obvious finding, any decision you made. If you realise later that you need the hidden detail, you can call `task_pick(task_id)` to re-expand the full log for one single request only.

### Rules
- Every non-task, non-goal tool call must be inside an `in_progress` task. Calls outside are rejected.
- Only one task `in_progress` at a time. Call `close_current_task` before `start_task` again.
- `close_current_task` must be the **first and only** tool call in its response. Do not call other tools in the same response. You need to have seen all tool results before closing so your memories are accurate.
- `close_current_task` is rejected if the task has zero memories — you must record at least one memory before closing.
- Tasks with status `in_progress` or `done` cannot be removed. They are frozen records.
- `task_pick(task_id)` expands a done task's full log for the **next request only**, then collapses again.

### Example
```
Response 1: create_task({description: 'Audit the auth middleware'})
            start_task({task_id: 1})
            open_file({path: 'src/auth/middleware.py'})
            ← you receive tool results
Response 2: task_memory({text: 'Middleware at src/auth/middleware.py lines 12-48. Uses jwt.decode() without verifying aud claim.'})
            task_memory({text: 'Session store is Redis, keys prefixed \"sess:\".'})
Response 3: close_current_task({})
```
Note that `close_current_task` is in a response by itself, after all memories have been saved."
