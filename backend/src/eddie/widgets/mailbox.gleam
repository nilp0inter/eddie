/// Mailbox widget — parent-child agent communication.
///
/// Protocol-free: all tools work without an active task.
/// Uses CmdEffect for broker communication (crossing actor boundaries).
///
/// Tools exposed depend on the agent's position in the tree:
/// - Has parent: send_to_parent
/// - Always: send_to_child
///
/// Incoming mail is delivered via the mail forwarder (agent_tree) which
/// injects user messages directly — no read tools needed.
///
/// The send_to_child tool is always available — child validation happens
/// at call time via a list_children_fn closure that queries the live tree.
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

import eddie/cmd.{type Cmd}
import eddie/coerce
import eddie/mailbox_broker.{type MailboxBrokerMessage}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/agent_info.{type AgentInfo}
import eddie_shared/initiator.{type Initiator, LLM, UI}
import eddie_shared/mailbox.{type MailMessage}
import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

import gleam/erlang/process.{type Subject}

// ============================================================================
// Model
// ============================================================================

/// Function that returns the current list of children for this agent.
/// Queries the agent tree at call time for a live view.
pub type ListChildrenFn =
  fn() -> List(AgentInfo)

pub type MailboxModel {
  MailboxModel(
    agent_id: String,
    parent_id: Option(String),
    list_children_fn: ListChildrenFn,
    inbox: List(MailMessage),
    outbox: List(MailMessage),
    broker: Subject(MailboxBrokerMessage),
  )
}

// ============================================================================
// Messages
// ============================================================================

pub type MailboxMsg {
  // LLM/UI tools
  SendToChild(child_id: String, content: String, initiator: Initiator)
  // Effect results
  SendResult(result: Result(MailMessage, String))
  ChildrenQueried(children: List(AgentInfo), child_id: String, content: String)
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: MailboxModel,
  msg: MailboxMsg,
) -> #(MailboxModel, Cmd(MailboxMsg)) {
  case msg {
    SendToChild(child_id, content, _initiator) -> {
      // Query children from the tree at call time (via CmdEffect)
      // to validate the child_id against the live tree state
      let list_fn = model.list_children_fn
      #(
        model,
        cmd.CmdEffect(
          perform: fn() {
            coerce.unsafe_coerce(ChildrenQueried(
              children: list_fn(),
              child_id: child_id,
              content: content,
            ))
          },
          to_msg: coerce.unsafe_coerce,
        ),
      )
    }

    ChildrenQueried(children, child_id, content) -> {
      let is_valid = list.any(children, fn(c) { c.id == child_id })
      case is_valid {
        False -> #(
          model,
          cmd.CmdToolResult(
            "Error: unknown child agent '"
            <> child_id
            <> "'. Known children: "
            <> case children {
              [] -> "none"
              _ ->
                list.map(children, fn(c) { c.id })
                |> string.join(", ")
            },
          ),
        )
        True -> {
          let broker = model.broker
          let from = model.agent_id
          #(
            model,
            cmd.CmdEffect(
              perform: fn() {
                coerce.unsafe_coerce(
                  SendResult(result: mailbox_broker.send_mail(
                    broker: broker,
                    from: from,
                    from_label: from,
                    to: child_id,
                    content: content,
                  )),
                )
              },
              to_msg: coerce.unsafe_coerce,
            ),
          )
        }
      }
    }

    SendResult(result) -> {
      case result {
        Ok(mail) -> {
          let new_outbox = list.append(model.outbox, [mail])
          #(
            MailboxModel(..model, outbox: new_outbox),
            cmd.CmdToolResult("Message sent to " <> mail.to),
          )
        }
        Error(err) -> #(model, cmd.CmdToolResult("Send failed: " <> err))
      }
    }
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: MailboxModel) -> List(Message) {
  let header = "## Mailbox"
  let parent_line = case model.parent_id {
    None -> "Parent: none (root agent)"
    Some(pid) -> "Parent: " <> pid
  }
  let text = string.join([header, parent_line], "\n")
  [message.Request(parts: [message.UserPart(text)])]
}

fn view_tools(_model: MailboxModel) -> List(ToolDefinition) {
  let assert Ok(child_tool) =
    tool.new(
      name: "send_to_child",
      description: "Send a message to one of your child agents by ID. Use list_subagents first to see available children.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "child_id",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("The ID of the child agent to message."),
                ),
              ]),
            ),
            #(
              "message",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("The message content to send.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["child_id", "message"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  [child_tool]
}

fn view_state(model: MailboxModel) -> List(ServerEvent) {
  [protocol.MailboxUpdated(inbox: model.inbox, outbox: model.outbox)]
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: MailboxModel,
  tool_name: String,
  args: Dynamic,
) -> Result(MailboxMsg, String) {
  case tool_name {
    "send_to_child" -> {
      let decoder = {
        use child_id <- decode.field("child_id", decode.string)
        use content <- decode.field("message", decode.string)
        decode.success(#(child_id, content))
      }
      case decode.run(args, decoder) {
        Ok(#(child_id, content)) ->
          Ok(SendToChild(child_id: child_id, content: content, initiator: LLM))
        Error(_) ->
          Error("send_to_child: missing 'child_id' or 'message' field")
      }
    }
    _ -> Error("Mailbox: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: MailboxModel,
  event_name: String,
  args: Dynamic,
) -> Option(MailboxMsg) {
  case event_name {
    "send_to_child" -> {
      let decoder = {
        use child_id <- decode.field("child_id", decode.string)
        use content <- decode.field("message", decode.string)
        decode.success(#(child_id, content))
      }
      case decode.run(args, decoder) {
        Ok(#(child_id, content)) ->
          Some(SendToChild(child_id: child_id, content: content, initiator: UI))
        Error(_) -> None
      }
    }
    _ -> None
  }
}

// ============================================================================
// Factory
// ============================================================================

/// Create a mailbox widget for an agent.
pub fn create(
  agent_id agent_id: String,
  parent_id parent_id: Option(String),
  list_children_fn list_children_fn: ListChildrenFn,
  broker broker: Subject(MailboxBrokerMessage),
) -> WidgetHandle {
  let all_tools = ["send_to_child"]
  widget.create(widget.WidgetConfig(
    id: "mailbox",
    model: MailboxModel(
      agent_id: agent_id,
      parent_id: parent_id,
      list_children_fn: list_children_fn,
      inbox: [],
      outbox: [],
      broker: broker,
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
