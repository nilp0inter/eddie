import gleam/option.{None, Some}
import gleam/set
import gleeunit/should

import eddie/widgets/task_protocol

// ============================================================================
// check — protocol enforcement
// ============================================================================

pub fn check_allows_task_management_test() {
  let tasks = task_protocol.new_empty_tasks()
  let free = set.new()

  task_protocol.check(
    active_task_id: None,
    tasks: tasks,
    tool_name: "create_task",
    protocol_free_tools: free,
  )
  |> should.equal(None)

  task_protocol.check(
    active_task_id: None,
    tasks: tasks,
    tool_name: "task_pick",
    protocol_free_tools: free,
  )
  |> should.equal(None)

  task_protocol.check(
    active_task_id: None,
    tasks: tasks,
    tool_name: "remove_task",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}

pub fn check_blocks_tool_outside_task_test() {
  let tasks = task_protocol.new_empty_tasks()
  let free = set.new()

  let result =
    task_protocol.check(
      active_task_id: None,
      tasks: tasks,
      tool_name: "open_file",
      protocol_free_tools: free,
    )
  result |> should.be_some
}

pub fn check_allows_protocol_free_tools_test() {
  let tasks = task_protocol.new_empty_tasks()
  let free = set.from_list(["set_goal"])

  task_protocol.check(
    active_task_id: None,
    tasks: tasks,
    tool_name: "set_goal",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}

pub fn check_allows_tool_inside_task_test() {
  let tasks = task_protocol.new_empty_tasks()
  let free = set.new()

  task_protocol.check(
    active_task_id: Some(1),
    tasks: tasks,
    tool_name: "open_file",
    protocol_free_tools: free,
  )
  |> should.equal(None)
}
