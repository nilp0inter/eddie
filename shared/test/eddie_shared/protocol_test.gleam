import eddie_shared/message
import eddie_shared/protocol
import eddie_shared/task
import eddie_shared/turn_result
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

// ============================================================================
// Helper: encode then decode, assert roundtrip
// ============================================================================

fn roundtrip_server_event(event: protocol.ServerEvent) -> Nil {
  event
  |> protocol.server_event_to_json
  |> json.to_string
  |> json.parse(protocol.server_event_decoder())
  |> should.equal(Ok(event))
}

fn roundtrip_client_command(command: protocol.ClientCommand) -> Nil {
  command
  |> protocol.client_command_to_json
  |> json.to_string
  |> json.parse(protocol.client_command_decoder())
  |> should.equal(Ok(command))
}

// ============================================================================
// ServerEvent roundtrip tests
// ============================================================================

pub fn agent_state_snapshot_roundtrip_test() {
  roundtrip_server_event(
    protocol.AgentStateSnapshot(
      agent_id: "agent-1",
      goal: Some("Build a thing"),
      system_prompt: "You are helpful",
      tasks: [
        protocol.TaskSnapshot(
          id: 1,
          description: "Do stuff",
          status: task.InProgress,
          memories: ["remember this"],
          ui_expanded: True,
        ),
      ],
      log: [
        protocol.UserMessageSnapshot(text: "hello", owning_task_id: Some(1)),
        protocol.ResponseSnapshot(
          response: message.Response(parts: [
            message.TextPart(content: "hi there"),
          ]),
          owning_task_id: Some(1),
        ),
        protocol.ToolResultsSnapshot(
          request: message.Request(parts: [
            message.ToolReturnPart(
              tool_name: "read",
              content: "file contents",
              tool_call_id: "tc-1",
            ),
          ]),
          owning_task_id: None,
        ),
      ],
      directories: [
        protocol.DirectorySnapshot(path: "/home", entries: [
          #("user", True),
          #("file.txt", False),
        ]),
      ],
      files: [protocol.FileSnapshot(path: "/home/file.txt", content: "data")],
      token_records: [
        protocol.TokenRecord(
          request_number: 1,
          input_tokens: 100,
          output_tokens: 50,
        ),
      ],
    ),
  )
}

pub fn agent_state_snapshot_empty_roundtrip_test() {
  roundtrip_server_event(
    protocol.AgentStateSnapshot(
      agent_id: "a",
      goal: None,
      system_prompt: "",
      tasks: [],
      log: [],
      directories: [],
      files: [],
      token_records: [],
    ),
  )
}

pub fn goal_updated_roundtrip_test() {
  roundtrip_server_event(protocol.GoalUpdated(text: Some("New goal")))
  roundtrip_server_event(protocol.GoalUpdated(text: None))
}

pub fn system_prompt_updated_roundtrip_test() {
  roundtrip_server_event(protocol.SystemPromptUpdated(text: "Be concise"))
}

pub fn conversation_appended_user_roundtrip_test() {
  roundtrip_server_event(
    protocol.ConversationAppended(item: protocol.UserMessageSnapshot(
      text: "hi",
      owning_task_id: None,
    )),
  )
}

pub fn conversation_appended_response_roundtrip_test() {
  roundtrip_server_event(
    protocol.ConversationAppended(item: protocol.ResponseSnapshot(
      response: message.Response(parts: [
        message.TextPart(content: "hello"),
        message.ToolCallPart(
          tool_name: "search",
          arguments_json: "{}",
          tool_call_id: "tc-2",
        ),
      ]),
      owning_task_id: Some(5),
    )),
  )
}

pub fn conversation_appended_tool_results_roundtrip_test() {
  roundtrip_server_event(
    protocol.ConversationAppended(item: protocol.ToolResultsSnapshot(
      request: message.Request(parts: [
        message.ToolReturnPart(
          tool_name: "search",
          content: "found it",
          tool_call_id: "tc-2",
        ),
      ]),
      owning_task_id: None,
    )),
  )
}

pub fn task_created_roundtrip_test() {
  roundtrip_server_event(protocol.TaskCreated(id: 3, description: "Fix bug"))
}

pub fn task_status_changed_roundtrip_test() {
  roundtrip_server_event(protocol.TaskStatusChanged(id: 1, status: task.Done))
  roundtrip_server_event(protocol.TaskStatusChanged(id: 2, status: task.Pending))
}

pub fn task_memory_added_roundtrip_test() {
  roundtrip_server_event(protocol.TaskMemoryAdded(id: 1, text: "note"))
}

pub fn task_memory_removed_roundtrip_test() {
  roundtrip_server_event(protocol.TaskMemoryRemoved(id: 1, index: 0))
}

pub fn task_memory_edited_roundtrip_test() {
  roundtrip_server_event(protocol.TaskMemoryEdited(
    id: 1,
    index: 2,
    new_text: "updated",
  ))
}

pub fn tokens_used_roundtrip_test() {
  roundtrip_server_event(protocol.TokensUsed(input: 500, output: 200))
}

pub fn file_explorer_updated_roundtrip_test() {
  roundtrip_server_event(
    protocol.FileExplorerUpdated(
      directories: [
        protocol.DirectorySnapshot(path: "/", entries: [#("home", True)]),
      ],
      files: [protocol.FileSnapshot(path: "/readme.md", content: "# Hi")],
    ),
  )
}

pub fn tool_call_started_roundtrip_test() {
  roundtrip_server_event(protocol.ToolCallStarted(
    name: "read_file",
    args_json: "{\"path\": \"/tmp\"}",
    call_id: "call-1",
  ))
}

pub fn tool_call_completed_roundtrip_test() {
  roundtrip_server_event(protocol.ToolCallCompleted(
    name: "read_file",
    result: "contents",
    call_id: "call-1",
  ))
}

pub fn turn_started_roundtrip_test() {
  roundtrip_server_event(protocol.TurnStarted)
}

pub fn turn_completed_success_roundtrip_test() {
  roundtrip_server_event(
    protocol.TurnCompleted(result: turn_result.TurnSuccess(text: "Done!")),
  )
}

pub fn turn_completed_error_roundtrip_test() {
  roundtrip_server_event(
    protocol.TurnCompleted(result: turn_result.TurnError(reason: "timeout")),
  )
}

pub fn agent_error_roundtrip_test() {
  roundtrip_server_event(protocol.AgentError(reason: "crash"))
}

// ============================================================================
// Message part roundtrip tests
// ============================================================================

pub fn message_part_system_roundtrip_test() {
  let part = message.SystemPart(content: "Be helpful")
  part
  |> message.message_part_to_json
  |> json.to_string
  |> json.parse(message.message_part_decoder())
  |> should.equal(Ok(part))
}

pub fn message_part_tool_call_roundtrip_test() {
  let part =
    message.ToolCallPart(
      tool_name: "search",
      arguments_json: "{\"q\":\"test\"}",
      tool_call_id: "tc-99",
    )
  part
  |> message.message_part_to_json
  |> json.to_string
  |> json.parse(message.message_part_decoder())
  |> should.equal(Ok(part))
}

pub fn message_part_retry_roundtrip_test() {
  let part =
    message.RetryPart(
      tool_name: "validate",
      content: "bad input",
      tool_call_id: "tc-5",
    )
  part
  |> message.message_part_to_json
  |> json.to_string
  |> json.parse(message.message_part_decoder())
  |> should.equal(Ok(part))
}

// ============================================================================
// ClientCommand roundtrip tests
// ============================================================================

pub fn send_user_message_roundtrip_test() {
  roundtrip_client_command(protocol.SendUserMessage(text: "hello"))
}

pub fn set_goal_roundtrip_test() {
  roundtrip_client_command(protocol.SetGoal(text: "win"))
}

pub fn clear_goal_roundtrip_test() {
  roundtrip_client_command(protocol.ClearGoal)
}

pub fn set_system_prompt_roundtrip_test() {
  roundtrip_client_command(protocol.SetSystemPrompt(text: "be brief"))
}

pub fn reset_system_prompt_roundtrip_test() {
  roundtrip_client_command(protocol.ResetSystemPrompt)
}

pub fn create_task_roundtrip_test() {
  roundtrip_client_command(protocol.CreateTask(description: "new task"))
}

pub fn start_task_roundtrip_test() {
  roundtrip_client_command(protocol.StartTask(task_id: 1))
}

pub fn close_current_task_roundtrip_test() {
  roundtrip_client_command(protocol.CloseCurrentTask)
}

pub fn task_memory_cmd_roundtrip_test() {
  roundtrip_client_command(protocol.TaskMemoryCmd(text: "remember"))
}

pub fn pick_task_roundtrip_test() {
  roundtrip_client_command(protocol.PickTask(task_id: 7))
}

pub fn remove_task_roundtrip_test() {
  roundtrip_client_command(protocol.RemoveTask(task_id: 3))
}

pub fn edit_memory_roundtrip_test() {
  roundtrip_client_command(protocol.EditMemory(
    task_id: 1,
    index: 0,
    new_text: "updated note",
  ))
}

pub fn remove_memory_roundtrip_test() {
  roundtrip_client_command(protocol.RemoveMemory(task_id: 1, index: 2))
}

pub fn toggle_task_expanded_roundtrip_test() {
  roundtrip_client_command(protocol.ToggleTaskExpanded(task_id: 4))
}

pub fn open_directory_roundtrip_test() {
  roundtrip_client_command(protocol.OpenDirectory(path: "/home"))
}

pub fn close_directory_roundtrip_test() {
  roundtrip_client_command(protocol.CloseDirectory(path: "/home"))
}

pub fn read_file_roundtrip_test() {
  roundtrip_client_command(protocol.ReadFile(path: "/home/file.txt"))
}

pub fn close_read_file_roundtrip_test() {
  roundtrip_client_command(protocol.CloseReadFile(path: "/home/file.txt"))
}
