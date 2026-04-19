/// The WebSocket protocol between backend and frontend.
///
/// ServerEvent flows backend → frontend.
/// ClientCommand flows frontend → backend.
///
/// Both user and LLM are external to the agent — they interact with it
/// through these message types. The user and LLM are nearly equal partners
/// when interacting with the agent's state.
import gleam/option.{type Option}

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
