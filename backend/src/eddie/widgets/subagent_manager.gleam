/// Subagent Manager widget — gives agents the ability to spawn child agents.
///
/// Protocol-free: all tools work without an active task.
/// Uses CmdEffect for agent_tree communication (crossing actor boundaries).
///
/// Tools:
/// - spawn_subagent: create a child agent with a goal and initial message
/// - list_subagents: show current children and their statuses
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

import eddie/cmd.{type Cmd}
import eddie/coerce
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/agent_info.{type AgentInfo}


import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

// ============================================================================
// Model
// ============================================================================

/// Function that spawns a child agent. Returns Ok on success.
/// Arguments: id, label, goal, initial_message, system_prompt
pub type SpawnFn =
  fn(String, String, String, String, String) -> Result(Nil, String)

/// Function that lists children. Returns a list of AgentInfo.
pub type ListChildrenFn =
  fn() -> List(AgentInfo)

pub type SubagentManagerModel {
  SubagentManagerModel(
    agent_id: String,
    spawn_fn: SpawnFn,
    list_children_fn: ListChildrenFn,
    children: List(SubagentInfo),
    next_child_number: Int,
  )
}

pub type SubagentInfo {
  SubagentInfo(id: String, label: String, goal: String)
}

// ============================================================================
// Messages
// ============================================================================

pub type SubagentManagerMsg {
  // LLM tools
  SpawnSubagent(label: String, goal: String, initial_message: String)
  ListSubagents
  // Effect results
  SpawnResult(result: Result(Nil, String), info: SubagentInfo)
  ChildrenListed(children: List(AgentInfo))
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: SubagentManagerModel,
  msg: SubagentManagerMsg,
) -> #(SubagentManagerModel, Cmd(SubagentManagerMsg)) {
  case msg {
    SpawnSubagent(label, goal, initial_message) -> {
      let child_id = generate_uuid()
      let system_prompt =
        "You are "
        <> label
        <> ". Your goal: "
        <> goal
        <> "\n\nWork autonomously to achieve this goal. When done, send a message to your parent with your findings using the send_to_parent tool."
      let info = SubagentInfo(id: child_id, label: label, goal: goal)
      let spawn_fn = model.spawn_fn
      #(
        model,
        cmd.CmdEffect(
          perform: fn() {
            coerce.unsafe_coerce(
              SpawnResult(
                result: spawn_fn(
                  child_id,
                  label,
                  goal,
                  initial_message,
                  system_prompt,
                ),
                info: info,
              ),
            )
          },
          to_msg: coerce.unsafe_coerce,
        ),
      )
    }

    ListSubagents -> {
      let list_fn = model.list_children_fn
      #(
        model,
        cmd.CmdEffect(
          perform: fn() {
            coerce.unsafe_coerce(ChildrenListed(children: list_fn()))
          },
          to_msg: coerce.unsafe_coerce,
        ),
      )
    }

    SpawnResult(result, info) -> {
      case result {
        Ok(_) -> {
          let new_children = list.append(model.children, [info])
          #(
            SubagentManagerModel(
              ..model,
              children: new_children,
              next_child_number: model.next_child_number + 1,
            ),
            cmd.CmdToolResult(
              "Spawned subagent '"
              <> info.label
              <> "' (id: "
              <> info.id
              <> "). It is now running with goal: "
              <> info.goal,
            ),
          )
        }
        Error(err) -> #(model, cmd.CmdToolResult("Error: " <> err))
      }
    }

    ChildrenListed(children) -> {
      let text = case children {
        [] -> "No subagents."
        _ ->
          "Subagents ("
          <> int.to_string(list.length(children))
          <> "):\n"
          <> format_children(children, model.children)
      }
      #(model, cmd.CmdToolResult(text))
    }
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: SubagentManagerModel) -> List(Message) {
  let header = "## Subagents"
  let body = case model.children {
    [] -> "No subagents spawned."
    children ->
      list.map(children, fn(c) {
        "- " <> c.label <> " (" <> c.id <> "): " <> c.goal
      })
      |> string.join("\n")
  }
  let text = header <> "\n" <> body
  [message.Request(parts: [message.UserPart(text)])]
}

fn view_tools(_model: SubagentManagerModel) -> List(ToolDefinition) {
  let assert Ok(spawn_tool) =
    tool.new(
      name: "spawn_subagent",
      description: "Spawn a new child agent to work on a subtask autonomously. Give it a clear goal and an initial message to start working on.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "label",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "A short name for the subagent (e.g. 'Research Agent').",
                  ),
                ),
              ]),
            ),
            #(
              "goal",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("The goal for the subagent to accomplish."),
                ),
              ]),
            ),
            #(
              "initial_message",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string(
                    "The first message to send to the subagent (as if from a user).",
                  ),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "required",
          json.array(["label", "goal", "initial_message"], json.string),
        ),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(list_tool) =
    tool.new(
      name: "list_subagents",
      description: "List all spawned subagents and their current status.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  [spawn_tool, list_tool]
}

fn view_state(model: SubagentManagerModel) -> List(ServerEvent) {
  let infos =
    list.map(model.children, fn(c) {
      agent_info.AgentInfo(
        id: c.id,
        label: c.label,
        parent_id: Some(model.agent_id),
        status: agent_info.AgentIdle,
      )
    })
  [protocol.SubagentsUpdated(children: infos)]
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: SubagentManagerModel,
  tool_name: String,
  args: Dynamic,
) -> Result(SubagentManagerMsg, String) {
  case tool_name {
    "spawn_subagent" -> {
      let decoder = {
        use label <- decode.field("label", decode.string)
        use goal <- decode.field("goal", decode.string)
        use initial_message <- decode.field("initial_message", decode.string)
        decode.success(#(label, goal, initial_message))
      }
      case decode.run(args, decoder) {
        Ok(#(label, goal, initial_message)) ->
          Ok(SpawnSubagent(
            label: label,
            goal: goal,
            initial_message: initial_message,
          ))
        Error(_) ->
          Error(
            "spawn_subagent: missing 'label', 'goal', or 'initial_message' field",
          )
      }
    }
    "list_subagents" -> Ok(ListSubagents)
    _ -> Error("SubagentManager: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: SubagentManagerModel,
  event_name: String,
  _args: Dynamic,
) -> Option(SubagentManagerMsg) {
  case event_name {
    "list_subagents" -> Some(ListSubagents)
    _ -> None
  }
}

// ============================================================================
// Helpers
// ============================================================================

fn format_children(
  agent_infos: List(AgentInfo),
  local_infos: List(SubagentInfo),
) -> String {
  list.map(agent_infos, fn(ai) {
    let goal = case list.find(local_infos, fn(li) { li.id == ai.id }) {
      Ok(li) -> li.goal
      Error(_) -> "(unknown goal)"
    }
    "- "
    <> ai.label
    <> " ("
    <> ai.id
    <> "): "
    <> agent_info.status_to_string(ai.status)
    <> " — "
    <> goal
  })
  |> string.join("\n")
}

// ============================================================================
// Factory
// ============================================================================

/// Create a subagent manager widget for an agent.
pub fn create(
  agent_id agent_id: String,
  spawn_fn spawn_fn: SpawnFn,
  list_children_fn list_children_fn: ListChildrenFn,
) -> WidgetHandle {
  let all_tools = ["spawn_subagent", "list_subagents"]
  widget.create(widget.WidgetConfig(
    id: "subagent_manager",
    model: SubagentManagerModel(
      agent_id: agent_id,
      spawn_fn: spawn_fn,
      list_children_fn: list_children_fn,
      children: [],
      next_child_number: 1,
    ),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_state: view_state,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.from_list(all_tools),
    protocol_free_tools: set.from_list(all_tools),
  ))
}

@external(erlang, "eddie_ffi", "generate_uuid")
fn generate_uuid() -> String
