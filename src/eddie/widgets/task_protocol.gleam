/// Task protocol — types, rules, and enforcement for the task-partitioned
/// conversation memory system.
///
/// The task protocol governs when tool calls are allowed. Every non-task,
/// non-protocol-free tool call must happen inside an `in_progress` task.
/// This module defines the task lifecycle types and the protocol checking
/// logic, separate from the conversation log that records history.
import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}

// ============================================================================
// Types
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

// ============================================================================
// Protocol checking
// ============================================================================

/// Check if a tool call is allowed under the task protocol.
/// Returns Some(error_message) if the call violates the protocol,
/// or None if it's allowed.
pub fn check(
  active_task_id active_task_id: Option(Int),
  tasks tasks: Dict(Int, Task),
  tool_name tool_name: String,
  protocol_free_tools protocol_free_tools: Set(String),
) -> Option(String) {
  case tool_name {
    // Task management tools — always callable
    "create_task" | "task_pick" | "remove_task" -> None
    "start_task" ->
      case active_task_id {
        Some(active_id) ->
          Some(
            "Cannot start a task while task "
            <> int.to_string(active_id)
            <> " is in_progress. Call close_current_task first.",
          )
        None -> None
      }
    "close_current_task" -> check_close(active_task_id:, tasks:)
    "task_memory" ->
      case active_task_id {
        None ->
          Some(
            "Cannot append memory outside a task. Start a task first with start_task(task_id).",
          )
        Some(_) -> None
      }
    // Any other tool — allowed iff a task is active or tool is protocol-free
    _ ->
      case active_task_id {
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

fn check_close(
  active_task_id active_task_id: Option(Int),
  tasks tasks: Dict(Int, Task),
) -> Option(String) {
  case active_task_id {
    None -> Some("No task is in_progress; nothing to close.")
    Some(tid) -> {
      let has_memories =
        dict.get(tasks, tid)
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

// ============================================================================
// Helpers
// ============================================================================

/// Create an empty tasks dict.
pub fn new_empty_tasks() -> Dict(Int, Task) {
  dict.new()
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

// ============================================================================
// Protocol rules text (shown to the LLM as a system prompt)
// ============================================================================

pub const rules = "## Task Protocol — conversation memory management

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
