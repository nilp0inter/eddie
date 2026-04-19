/// The WebSocket protocol between backend and frontend.
///
/// ServerEvent flows backend → frontend.
/// ClientCommand flows frontend → backend.
///
/// Both user and LLM are external to the agent — they interact with it
/// through these message types. The user and LLM are nearly equal partners
/// when interacting with the agent's state.
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

import eddie_shared/agent_info.{type AgentInfo, type AgentStatus, type AgentTreeNode}
import eddie_shared/mailbox.{type MailMessage}
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
  /// The agent tree structure changed (agent spawned/removed).
  AgentTreeChanged(roots: List(AgentTreeNode))
  /// A spawn request failed.
  AgentSpawnFailed(id: String, reason: String)
  /// A child agent's status changed.
  ChildAgentStatusChanged(agent_id: String, status: AgentStatus)
  /// The subagents list for a parent agent was updated.
  SubagentsUpdated(children: List(AgentInfo))
  /// A mail message was received in this agent's inbox.
  MailReceived(message: MailMessage)
  /// A mail message was sent from this agent's outbox.
  MailSent(message: MailMessage)
  /// Full mailbox state update.
  MailboxUpdated(inbox: List(MailMessage), outbox: List(MailMessage))
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
  /// Spawn a new root agent (server generates UUID + default label).
  SpawnRootAgent
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

pub fn agent_info_to_json(info: AgentInfo) -> json.Json {
  agent_info.agent_info_to_json(info)
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
    AgentTreeChanged(roots) ->
      json.object([
        #("type", json.string("agent_tree_changed")),
        #("roots", json.array(roots, agent_info.agent_tree_node_to_json)),
      ])
    AgentSpawnFailed(id, reason) ->
      json.object([
        #("type", json.string("agent_spawn_failed")),
        #("id", json.string(id)),
        #("reason", json.string(reason)),
      ])
    ChildAgentStatusChanged(agent_id, status) ->
      json.object([
        #("type", json.string("child_agent_status_changed")),
        #("agent_id", json.string(agent_id)),
        #("status", agent_info.status_to_json(status)),
      ])
    SubagentsUpdated(children) ->
      json.object([
        #("type", json.string("subagents_updated")),
        #("children", json.array(children, agent_info_to_json)),
      ])
    MailReceived(message) ->
      json.object([
        #("type", json.string("mail_received")),
        #("message", mailbox.mail_message_to_json(message)),
      ])
    MailSent(message) ->
      json.object([
        #("type", json.string("mail_sent")),
        #("message", mailbox.mail_message_to_json(message)),
      ])
    MailboxUpdated(inbox, outbox) ->
      json.object([
        #("type", json.string("mailbox_updated")),
        #("inbox", json.array(inbox, mailbox.mail_message_to_json)),
        #("outbox", json.array(outbox, mailbox.mail_message_to_json)),
      ])
  }
}

/// Encode a list of server events to a JSON string.
pub fn server_events_to_json_string(events: List(ServerEvent)) -> String {
  json.to_string(json.array(events, server_event_to_json))
}

// ============================================================================
// ClientCommand JSON encoding
// ============================================================================

pub fn client_command_to_json(command: ClientCommand) -> json.Json {
  case command {
    SendUserMessage(text) ->
      json.object([
        #("type", json.string("send_user_message")),
        #("text", json.string(text)),
      ])
    SetGoal(text) ->
      json.object([
        #("type", json.string("set_goal")),
        #("text", json.string(text)),
      ])
    ClearGoal -> json.object([#("type", json.string("clear_goal"))])
    SetSystemPrompt(text) ->
      json.object([
        #("type", json.string("set_system_prompt")),
        #("text", json.string(text)),
      ])
    ResetSystemPrompt ->
      json.object([#("type", json.string("reset_system_prompt"))])
    CreateTask(description) ->
      json.object([
        #("type", json.string("create_task")),
        #("description", json.string(description)),
      ])
    StartTask(task_id) ->
      json.object([
        #("type", json.string("start_task")),
        #("task_id", json.int(task_id)),
      ])
    CloseCurrentTask ->
      json.object([#("type", json.string("close_current_task"))])
    TaskMemoryCmd(text) ->
      json.object([
        #("type", json.string("task_memory_cmd")),
        #("text", json.string(text)),
      ])
    PickTask(task_id) ->
      json.object([
        #("type", json.string("pick_task")),
        #("task_id", json.int(task_id)),
      ])
    RemoveTask(task_id) ->
      json.object([
        #("type", json.string("remove_task")),
        #("task_id", json.int(task_id)),
      ])
    EditMemory(task_id, index, new_text) ->
      json.object([
        #("type", json.string("edit_memory")),
        #("task_id", json.int(task_id)),
        #("index", json.int(index)),
        #("new_text", json.string(new_text)),
      ])
    RemoveMemory(task_id, index) ->
      json.object([
        #("type", json.string("remove_memory")),
        #("task_id", json.int(task_id)),
        #("index", json.int(index)),
      ])
    ToggleTaskExpanded(task_id) ->
      json.object([
        #("type", json.string("toggle_task_expanded")),
        #("task_id", json.int(task_id)),
      ])
    OpenDirectory(path) ->
      json.object([
        #("type", json.string("open_directory")),
        #("path", json.string(path)),
      ])
    CloseDirectory(path) ->
      json.object([
        #("type", json.string("close_directory")),
        #("path", json.string(path)),
      ])
    ReadFile(path) ->
      json.object([
        #("type", json.string("read_file")),
        #("path", json.string(path)),
      ])
    CloseReadFile(path) ->
      json.object([
        #("type", json.string("close_read_file")),
        #("path", json.string(path)),
      ])
    SpawnRootAgent ->
      json.object([#("type", json.string("spawn_root_agent"))])
  }
}

// ============================================================================
// JSON decoding
// ============================================================================

pub fn task_snapshot_decoder() -> decode.Decoder(TaskSnapshot) {
  use id <- decode.field("id", decode.int)
  use description <- decode.field("description", decode.string)
  use status <- decode.field("status", task.status_decoder())
  use memories <- decode.field("memories", decode.list(decode.string))
  use ui_expanded <- decode.field("ui_expanded", decode.bool)
  decode.success(TaskSnapshot(
    id:,
    description:,
    status:,
    memories:,
    ui_expanded:,
  ))
}

pub fn log_item_snapshot_decoder() -> decode.Decoder(LogItemSnapshot) {
  use type_tag <- decode.field("type", decode.string)
  case type_tag {
    "user_message" -> {
      use text <- decode.field("text", decode.string)
      use owning_task_id <- decode.field(
        "owning_task_id",
        decode.optional(decode.int),
      )
      decode.success(UserMessageSnapshot(text:, owning_task_id:))
    }
    "response" -> {
      use response <- decode.field("response", message.message_decoder())
      use owning_task_id <- decode.field(
        "owning_task_id",
        decode.optional(decode.int),
      )
      decode.success(ResponseSnapshot(response:, owning_task_id:))
    }
    "tool_results" -> {
      use request <- decode.field("request", message.message_decoder())
      use owning_task_id <- decode.field(
        "owning_task_id",
        decode.optional(decode.int),
      )
      decode.success(ToolResultsSnapshot(request:, owning_task_id:))
    }
    _ -> decode.failure(UserMessageSnapshot("", None), "LogItemSnapshot")
  }
}

pub fn directory_snapshot_decoder() -> decode.Decoder(DirectorySnapshot) {
  use path <- decode.field("path", decode.string)
  use entries <- decode.field(
    "entries",
    decode.list({
      use name <- decode.field("name", decode.string)
      use is_directory <- decode.field("is_directory", decode.bool)
      decode.success(#(name, is_directory))
    }),
  )
  decode.success(DirectorySnapshot(path:, entries:))
}

pub fn file_snapshot_decoder() -> decode.Decoder(FileSnapshot) {
  use path <- decode.field("path", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(FileSnapshot(path:, content:))
}

pub fn token_record_decoder() -> decode.Decoder(TokenRecord) {
  use request_number <- decode.field("request_number", decode.int)
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  decode.success(TokenRecord(request_number:, input_tokens:, output_tokens:))
}

pub fn agent_info_decoder() -> decode.Decoder(AgentInfo) {
  agent_info.agent_info_decoder()
}

pub fn server_event_decoder() -> decode.Decoder(ServerEvent) {
  use type_tag <- decode.field("type", decode.string)
  case type_tag {
    "agent_state_snapshot" -> {
      use agent_id <- decode.field("agent_id", decode.string)
      use goal <- decode.field("goal", decode.optional(decode.string))
      use system_prompt <- decode.field("system_prompt", decode.string)
      use tasks <- decode.field("tasks", decode.list(task_snapshot_decoder()))
      use log <- decode.field("log", decode.list(log_item_snapshot_decoder()))
      use directories <- decode.field(
        "directories",
        decode.list(directory_snapshot_decoder()),
      )
      use files <- decode.field("files", decode.list(file_snapshot_decoder()))
      use token_records <- decode.field(
        "token_records",
        decode.list(token_record_decoder()),
      )
      decode.success(AgentStateSnapshot(
        agent_id:,
        goal:,
        system_prompt:,
        tasks:,
        log:,
        directories:,
        files:,
        token_records:,
      ))
    }
    "goal_updated" -> {
      use text <- decode.field("text", decode.optional(decode.string))
      decode.success(GoalUpdated(text:))
    }
    "system_prompt_updated" -> {
      use text <- decode.field("text", decode.string)
      decode.success(SystemPromptUpdated(text:))
    }
    "conversation_appended" -> {
      use item <- decode.field("item", log_item_snapshot_decoder())
      decode.success(ConversationAppended(item:))
    }
    "task_created" -> {
      use id <- decode.field("id", decode.int)
      use description <- decode.field("description", decode.string)
      decode.success(TaskCreated(id:, description:))
    }
    "task_status_changed" -> {
      use id <- decode.field("id", decode.int)
      use status <- decode.field("status", task.status_decoder())
      decode.success(TaskStatusChanged(id:, status:))
    }
    "task_memory_added" -> {
      use id <- decode.field("id", decode.int)
      use text <- decode.field("text", decode.string)
      decode.success(TaskMemoryAdded(id:, text:))
    }
    "task_memory_removed" -> {
      use id <- decode.field("id", decode.int)
      use index <- decode.field("index", decode.int)
      decode.success(TaskMemoryRemoved(id:, index:))
    }
    "task_memory_edited" -> {
      use id <- decode.field("id", decode.int)
      use index <- decode.field("index", decode.int)
      use new_text <- decode.field("new_text", decode.string)
      decode.success(TaskMemoryEdited(id:, index:, new_text:))
    }
    "tokens_used" -> {
      use input <- decode.field("input", decode.int)
      use output <- decode.field("output", decode.int)
      decode.success(TokensUsed(input:, output:))
    }
    "file_explorer_updated" -> {
      use directories <- decode.field(
        "directories",
        decode.list(directory_snapshot_decoder()),
      )
      use files <- decode.field("files", decode.list(file_snapshot_decoder()))
      decode.success(FileExplorerUpdated(directories:, files:))
    }
    "tool_call_started" -> {
      use name <- decode.field("name", decode.string)
      use args_json <- decode.field("args_json", decode.string)
      use call_id <- decode.field("call_id", decode.string)
      decode.success(ToolCallStarted(name:, args_json:, call_id:))
    }
    "tool_call_completed" -> {
      use name <- decode.field("name", decode.string)
      use result <- decode.field("result", decode.string)
      use call_id <- decode.field("call_id", decode.string)
      decode.success(ToolCallCompleted(name:, result:, call_id:))
    }
    "turn_started" -> decode.success(TurnStarted)
    "turn_completed" -> {
      use result <- decode.field("result", turn_result.decoder())
      decode.success(TurnCompleted(result:))
    }
    "agent_error" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(AgentError(reason:))
    }
    "agent_tree_changed" -> {
      use roots <- decode.field(
        "roots",
        decode.list(agent_info.agent_tree_node_decoder()),
      )
      decode.success(AgentTreeChanged(roots:))
    }
    "agent_spawn_failed" -> {
      use id <- decode.field("id", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(AgentSpawnFailed(id:, reason:))
    }
    "child_agent_status_changed" -> {
      use agent_id <- decode.field("agent_id", decode.string)
      use status <- decode.field("status", agent_info.status_decoder())
      decode.success(ChildAgentStatusChanged(agent_id:, status:))
    }
    "subagents_updated" -> {
      use children <- decode.field(
        "children",
        decode.list(agent_info_decoder()),
      )
      decode.success(SubagentsUpdated(children:))
    }
    "mail_received" -> {
      use message <- decode.field("message", mailbox.mail_message_decoder())
      decode.success(MailReceived(message:))
    }
    "mail_sent" -> {
      use message <- decode.field("message", mailbox.mail_message_decoder())
      decode.success(MailSent(message:))
    }
    "mailbox_updated" -> {
      use inbox <- decode.field(
        "inbox",
        decode.list(mailbox.mail_message_decoder()),
      )
      use outbox <- decode.field(
        "outbox",
        decode.list(mailbox.mail_message_decoder()),
      )
      decode.success(MailboxUpdated(inbox:, outbox:))
    }
    _ -> decode.failure(TurnStarted, "ServerEvent")
  }
}

pub fn client_command_decoder() -> decode.Decoder(ClientCommand) {
  use type_tag <- decode.field("type", decode.string)
  case type_tag {
    "send_user_message" -> {
      use text <- decode.field("text", decode.string)
      decode.success(SendUserMessage(text:))
    }
    "set_goal" -> {
      use text <- decode.field("text", decode.string)
      decode.success(SetGoal(text:))
    }
    "clear_goal" -> decode.success(ClearGoal)
    "set_system_prompt" -> {
      use text <- decode.field("text", decode.string)
      decode.success(SetSystemPrompt(text:))
    }
    "reset_system_prompt" -> decode.success(ResetSystemPrompt)
    "create_task" -> {
      use description <- decode.field("description", decode.string)
      decode.success(CreateTask(description:))
    }
    "start_task" -> {
      use task_id <- decode.field("task_id", decode.int)
      decode.success(StartTask(task_id:))
    }
    "close_current_task" -> decode.success(CloseCurrentTask)
    "task_memory_cmd" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TaskMemoryCmd(text:))
    }
    "pick_task" -> {
      use task_id <- decode.field("task_id", decode.int)
      decode.success(PickTask(task_id:))
    }
    "remove_task" -> {
      use task_id <- decode.field("task_id", decode.int)
      decode.success(RemoveTask(task_id:))
    }
    "edit_memory" -> {
      use task_id <- decode.field("task_id", decode.int)
      use index <- decode.field("index", decode.int)
      use new_text <- decode.field("new_text", decode.string)
      decode.success(EditMemory(task_id:, index:, new_text:))
    }
    "remove_memory" -> {
      use task_id <- decode.field("task_id", decode.int)
      use index <- decode.field("index", decode.int)
      decode.success(RemoveMemory(task_id:, index:))
    }
    "toggle_task_expanded" -> {
      use task_id <- decode.field("task_id", decode.int)
      decode.success(ToggleTaskExpanded(task_id:))
    }
    "open_directory" -> {
      use path <- decode.field("path", decode.string)
      decode.success(OpenDirectory(path:))
    }
    "close_directory" -> {
      use path <- decode.field("path", decode.string)
      decode.success(CloseDirectory(path:))
    }
    "read_file" -> {
      use path <- decode.field("path", decode.string)
      decode.success(ReadFile(path:))
    }
    "close_read_file" -> {
      use path <- decode.field("path", decode.string)
      decode.success(CloseReadFile(path:))
    }
    "spawn_root_agent" -> decode.success(SpawnRootAgent)
    _ -> decode.failure(ClearGoal, "ClientCommand")
  }
}
