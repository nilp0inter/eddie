/// The WebSocket protocol between backend and frontend.
///
/// ServerEvent flows backend → frontend.
/// ClientCommand flows frontend → backend.
///
/// Both user and LLM are external to the agent — they interact with it
/// through these message types. The user and LLM are nearly equal partners
/// when interacting with the agent's state.
import gleam/json
import gleam/option.{type Option, None, Some}

import eddie_shared/message.{type Message}
import eddie_shared/task.{type TaskStatus}
import eddie_shared/turn_result.{type TurnResult}

// ============================================================================
// Backend → Frontend
// ============================================================================

/// Events the backend broadcasts to all connected frontends.
pub type ServerEvent {
  /// Full state snapshot sent on initial WebSocket connect.
  AgentStateSnapshot(
    agent_id: String,
    goal: Option(String),
    system_prompt: String,
    tasks: List(TaskSnapshot),
    log: List(LogItemSnapshot),
    directories: List(DirectorySnapshot),
    files: List(FileSnapshot),
    token_records: List(TokenRecord),
  )
  /// The agent's goal changed.
  GoalUpdated(text: Option(String))
  /// The system prompt was replaced.
  SystemPromptUpdated(text: String)
  /// A new item was appended to the conversation log.
  ConversationAppended(item: LogItemSnapshot)
  /// A new task was created.
  TaskCreated(id: Int, description: String)
  /// A task's status changed.
  TaskStatusChanged(id: Int, status: TaskStatus)
  /// A memory was appended to a task.
  TaskMemoryAdded(id: Int, text: String)
  /// A memory was removed from a task.
  TaskMemoryRemoved(id: Int, index: Int)
  /// A memory was edited in a task.
  TaskMemoryEdited(id: Int, index: Int, new_text: String)
  /// Token usage was recorded for a request.
  TokensUsed(input: Int, output: Int)
  /// The file explorer state changed.
  FileExplorerUpdated(
    directories: List(DirectorySnapshot),
    files: List(FileSnapshot),
  )
  /// A tool call started executing.
  ToolCallStarted(name: String, args_json: String, call_id: String)
  /// A tool call finished executing.
  ToolCallCompleted(name: String, result: String, call_id: String)
  /// An agent turn started (LLM request in flight).
  TurnStarted
  /// An agent turn completed.
  TurnCompleted(result: TurnResult)
  /// An unrecoverable agent error.
  AgentError(reason: String)
}

// ============================================================================
// Frontend → Backend
// ============================================================================

/// Commands the frontend sends to the backend.
pub type ClientCommand {
  /// Send a user message to the agent.
  SendUserMessage(text: String)
  /// Set the agent's goal.
  SetGoal(text: String)
  /// Clear the agent's goal.
  ClearGoal
  /// Replace the system prompt.
  SetSystemPrompt(text: String)
  /// Reset the system prompt to default.
  ResetSystemPrompt
  /// Create a new task.
  CreateTask(description: String)
  /// Start a pending task.
  StartTask(task_id: Int)
  /// Close the current in-progress task.
  CloseCurrentTask
  /// Append a memory to the active task.
  TaskMemoryCmd(text: String)
  /// Re-expand a done task for one request.
  PickTask(task_id: Int)
  /// Remove a pending task.
  RemoveTask(task_id: Int)
  /// Edit a task memory.
  EditMemory(task_id: Int, index: Int, new_text: String)
  /// Remove a task memory.
  RemoveMemory(task_id: Int, index: Int)
  /// Toggle task expansion in the UI.
  ToggleTaskExpanded(task_id: Int)
  /// Open a directory in the file explorer.
  OpenDirectory(path: String)
  /// Close a directory in the file explorer.
  CloseDirectory(path: String)
  /// Read a file in the file explorer.
  ReadFile(path: String)
  /// Close a read file in the file explorer.
  CloseReadFile(path: String)
}

// ============================================================================
// Snapshot types for state transfer
// ============================================================================

/// A task as seen by the frontend.
pub type TaskSnapshot {
  TaskSnapshot(
    id: Int,
    description: String,
    status: TaskStatus,
    memories: List(String),
    ui_expanded: Bool,
  )
}

/// A log entry as seen by the frontend.
pub type LogItemSnapshot {
  UserMessageSnapshot(text: String, owning_task_id: Option(Int))
  ResponseSnapshot(response: Message, owning_task_id: Option(Int))
  ToolResultsSnapshot(request: Message, owning_task_id: Option(Int))
}

/// An open directory in the file explorer.
pub type DirectorySnapshot {
  DirectorySnapshot(
    path: String,
    /// Each entry is (name, is_directory).
    entries: List(#(String, Bool)),
  )
}

/// An open file in the file explorer.
pub type FileSnapshot {
  FileSnapshot(path: String, content: String)
}

/// A single token usage record.
pub type TokenRecord {
  TokenRecord(request_number: Int, input_tokens: Int, output_tokens: Int)
}

// ============================================================================
// JSON encoding
// ============================================================================

fn option_string_to_json(value: Option(String)) -> json.Json {
  case value {
    Some(s) -> json.string(s)
    None -> json.null()
  }
}

fn option_int_to_json(value: Option(Int)) -> json.Json {
  case value {
    Some(n) -> json.int(n)
    None -> json.null()
  }
}

pub fn task_snapshot_to_json(snapshot: TaskSnapshot) -> json.Json {
  json.object([
    #("id", json.int(snapshot.id)),
    #("description", json.string(snapshot.description)),
    #("status", task.status_to_json(snapshot.status)),
    #("memories", json.array(snapshot.memories, json.string)),
    #("ui_expanded", json.bool(snapshot.ui_expanded)),
  ])
}

pub fn log_item_snapshot_to_json(item: LogItemSnapshot) -> json.Json {
  case item {
    UserMessageSnapshot(text, owning_task_id) ->
      json.object([
        #("type", json.string("user_message")),
        #("text", json.string(text)),
        #("owning_task_id", option_int_to_json(owning_task_id)),
      ])
    ResponseSnapshot(response, owning_task_id) ->
      json.object([
        #("type", json.string("response")),
        #("response", message.message_to_json(response)),
        #("owning_task_id", option_int_to_json(owning_task_id)),
      ])
    ToolResultsSnapshot(request, owning_task_id) ->
      json.object([
        #("type", json.string("tool_results")),
        #("request", message.message_to_json(request)),
        #("owning_task_id", option_int_to_json(owning_task_id)),
      ])
  }
}

pub fn directory_snapshot_to_json(snapshot: DirectorySnapshot) -> json.Json {
  json.object([
    #("path", json.string(snapshot.path)),
    #(
      "entries",
      json.array(snapshot.entries, fn(entry) {
        json.object([
          #("name", json.string(entry.0)),
          #("is_directory", json.bool(entry.1)),
        ])
      }),
    ),
  ])
}

pub fn file_snapshot_to_json(snapshot: FileSnapshot) -> json.Json {
  json.object([
    #("path", json.string(snapshot.path)),
    #("content", json.string(snapshot.content)),
  ])
}

pub fn token_record_to_json(record: TokenRecord) -> json.Json {
  json.object([
    #("request_number", json.int(record.request_number)),
    #("input_tokens", json.int(record.input_tokens)),
    #("output_tokens", json.int(record.output_tokens)),
  ])
}

pub fn server_event_to_json(event: ServerEvent) -> json.Json {
  case event {
    AgentStateSnapshot(
      agent_id,
      goal,
      system_prompt,
      tasks,
      log,
      directories,
      files,
      token_records,
    ) ->
      json.object([
        #("type", json.string("agent_state_snapshot")),
        #("agent_id", json.string(agent_id)),
        #("goal", option_string_to_json(goal)),
        #("system_prompt", json.string(system_prompt)),
        #("tasks", json.array(tasks, task_snapshot_to_json)),
        #("log", json.array(log, log_item_snapshot_to_json)),
        #("directories", json.array(directories, directory_snapshot_to_json)),
        #("files", json.array(files, file_snapshot_to_json)),
        #("token_records", json.array(token_records, token_record_to_json)),
      ])
    GoalUpdated(text) ->
      json.object([
        #("type", json.string("goal_updated")),
        #("text", option_string_to_json(text)),
      ])
    SystemPromptUpdated(text) ->
      json.object([
        #("type", json.string("system_prompt_updated")),
        #("text", json.string(text)),
      ])
    ConversationAppended(item) ->
      json.object([
        #("type", json.string("conversation_appended")),
        #("item", log_item_snapshot_to_json(item)),
      ])
    TaskCreated(id, description) ->
      json.object([
        #("type", json.string("task_created")),
        #("id", json.int(id)),
        #("description", json.string(description)),
      ])
    TaskStatusChanged(id, status) ->
      json.object([
        #("type", json.string("task_status_changed")),
        #("id", json.int(id)),
        #("status", task.status_to_json(status)),
      ])
    TaskMemoryAdded(id, text) ->
      json.object([
        #("type", json.string("task_memory_added")),
        #("id", json.int(id)),
        #("text", json.string(text)),
      ])
    TaskMemoryRemoved(id, index) ->
      json.object([
        #("type", json.string("task_memory_removed")),
        #("id", json.int(id)),
        #("index", json.int(index)),
      ])
    TaskMemoryEdited(id, index, new_text) ->
      json.object([
        #("type", json.string("task_memory_edited")),
        #("id", json.int(id)),
        #("index", json.int(index)),
        #("new_text", json.string(new_text)),
      ])
    TokensUsed(input, output) ->
      json.object([
        #("type", json.string("tokens_used")),
        #("input", json.int(input)),
        #("output", json.int(output)),
      ])
    FileExplorerUpdated(directories, files) ->
      json.object([
        #("type", json.string("file_explorer_updated")),
        #("directories", json.array(directories, directory_snapshot_to_json)),
        #("files", json.array(files, file_snapshot_to_json)),
      ])
    ToolCallStarted(name, args_json, call_id) ->
      json.object([
        #("type", json.string("tool_call_started")),
        #("name", json.string(name)),
        #("args_json", json.string(args_json)),
        #("call_id", json.string(call_id)),
      ])
    ToolCallCompleted(name, result, call_id) ->
      json.object([
        #("type", json.string("tool_call_completed")),
        #("name", json.string(name)),
        #("result", json.string(result)),
        #("call_id", json.string(call_id)),
      ])
    TurnStarted -> json.object([#("type", json.string("turn_started"))])
    TurnCompleted(result) ->
      json.object([
        #("type", json.string("turn_completed")),
        #("result", turn_result.to_json(result)),
      ])
    AgentError(reason) ->
      json.object([
        #("type", json.string("agent_error")),
        #("reason", json.string(reason)),
      ])
  }
}

/// Encode a list of server events to a JSON string.
pub fn server_events_to_json_string(events: List(ServerEvent)) -> String {
  json.to_string(json.array(events, server_event_to_json))
}
