/// Task types for the task-partitioned conversation memory system.
///
/// These are pure data types — the protocol rules and enforcement logic
/// live in the backend.
import gleam/json

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

pub fn status_to_string(status: TaskStatus) -> String {
  case status {
    Pending -> "pending"
    InProgress -> "in_progress"
    Done -> "done"
  }
}

pub fn status_icon(status: TaskStatus) -> String {
  case status {
    Pending -> "[ ]"
    InProgress -> "[~]"
    Done -> "[x]"
  }
}

pub fn parse_status(s: String) -> Result(TaskStatus, Nil) {
  case s {
    "pending" -> Ok(Pending)
    "in_progress" -> Ok(InProgress)
    "done" -> Ok(Done)
    _ -> Error(Nil)
  }
}

pub fn status_to_json(status: TaskStatus) -> json.Json {
  json.string(status_to_string(status))
}
