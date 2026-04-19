/// Mailbox widget — parent-child agent communication.
///
/// Protocol-free: all tools work without an active task.
/// Uses CmdEffect for broker communication (crossing actor boundaries).
///
/// Tools exposed depend on the agent's position in the tree:
/// - Has parent: send_to_parent
/// - Has children: send_to_child
/// - Always: read_mailbox, check_unread
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
import eddie/mailbox_broker.{type MailboxBrokerMessage}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/initiator.{type Initiator, LLM, UI}
import eddie_shared/mailbox.{type MailMessage}
import eddie_shared/message.{type Message}
import eddie_shared/protocol.{type ServerEvent}

import gleam/erlang/process.{type Subject}

// ============================================================================
// Model
// ============================================================================

pub type MailboxModel {
  MailboxModel(
    agent_id: String,
    parent_id: Option(String),
    child_ids: List(String),
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
  SendToParent(content: String, initiator: Initiator)
  SendToChild(child_id: String, content: String, initiator: Initiator)
  ReadMailbox(initiator: Initiator)
  CheckUnread(initiator: Initiator)
  // Effect results
  SendResult(result: Result(MailMessage, String))
  InboxLoaded(messages: List(MailMessage))
  UnreadLoaded(messages: List(MailMessage))
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: MailboxModel,
  msg: MailboxMsg,
) -> #(MailboxModel, Cmd(MailboxMsg)) {
  case msg {
    SendToParent(content, _initiator) -> {
      case model.parent_id {
        None -> #(model, cmd.CmdToolResult("Error: this agent has no parent"))
        Some(pid) -> {
          let broker = model.broker
          let from = model.agent_id
          #(
            model,
            cmd.CmdEffect(
              perform: fn() {
                coerce.unsafe_coerce(
                  SendResult(
                    result: mailbox_broker.send_mail(
                      broker: broker,
                      from: from,
                      to: pid,
                      content: content,
                    ),
                  ),
                )
              },
              to_msg: coerce.unsafe_coerce,
            ),
          )
        }
      }
    }

    SendToChild(child_id, content, _initiator) -> {
      let is_valid = list.contains(model.child_ids, child_id)
      case is_valid {
        False -> #(
          model,
          cmd.CmdToolResult("Error: unknown child agent '" <> child_id <> "'"),
        )
        True -> {
          let broker = model.broker
          let from = model.agent_id
          #(
            model,
            cmd.CmdEffect(
              perform: fn() {
                coerce.unsafe_coerce(
                  SendResult(
                    result: mailbox_broker.send_mail(
                      broker: broker,
                      from: from,
                      to: child_id,
                      content: content,
                    ),
                  ),
                )
              },
              to_msg: coerce.unsafe_coerce,
            ),
          )
        }
      }
    }

    ReadMailbox(_initiator) -> {
      let broker = model.broker
      let agent_id = model.agent_id
      #(
        model,
        cmd.CmdEffect(
          perform: fn() {
            coerce.unsafe_coerce(
              InboxLoaded(
                messages: mailbox_broker.read_mail(
                  broker: broker,
                  agent_id: agent_id,
                ),
              ),
            )
          },
          to_msg: coerce.unsafe_coerce,
        ),
      )
    }

    CheckUnread(_initiator) -> {
      let broker = model.broker
      let agent_id = model.agent_id
      #(
        model,
        cmd.CmdEffect(
          perform: fn() {
            coerce.unsafe_coerce(
              UnreadLoaded(
                messages: mailbox_broker.read_unread(
                  broker: broker,
                  agent_id: agent_id,
                ),
              ),
            )
          },
          to_msg: coerce.unsafe_coerce,
        ),
      )
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

    InboxLoaded(messages) -> {
      let text = format_inbox(messages)
      #(MailboxModel(..model, inbox: messages), cmd.CmdToolResult(text))
    }

    UnreadLoaded(messages) -> {
      let text = case messages {
        [] -> "No unread messages."
        _ ->
          "Unread messages ("
          <> int.to_string(list.length(messages))
          <> "):\n"
          <> format_message_list(messages)
      }
      // Update inbox with these (mark rest as read effectively)
      #(model, cmd.CmdToolResult(text))
    }
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: MailboxModel) -> List(Message) {
  let unread_count =
    list.count(model.inbox, fn(m) { !m.read })
  let header = "## Mailbox"
  let status =
    "Inbox: "
    <> int.to_string(list.length(model.inbox))
    <> " messages ("
    <> int.to_string(unread_count)
    <> " unread)"
  let parent_line = case model.parent_id {
    None -> "Parent: none (root agent)"
    Some(pid) -> "Parent: " <> pid
  }
  let children_line = case model.child_ids {
    [] -> "Children: none"
    ids -> "Children: " <> string.join(ids, ", ")
  }
  let text = string.join([header, status, parent_line, children_line], "\n")
  [message.Request(parts: [message.UserPart(text)])]
}

fn view_tools(model: MailboxModel) -> List(ToolDefinition) {
  let parent_tools = case model.parent_id {
    None -> []
    Some(_) -> {
      let assert Ok(t) =
        tool.new(
          name: "send_to_parent",
          description: "Send a message to your parent agent.",
          parameters_json: json.object([
            #("type", json.string("object")),
            #(
              "properties",
              json.object([
                #(
                  "message",
                  json.object([
                    #("type", json.string("string")),
                    #(
                      "description",
                      json.string("The message content to send."),
                    ),
                  ]),
                ),
              ]),
            ),
            #("required", json.array(["message"], json.string)),
            #("additionalProperties", json.bool(False)),
          ]),
        )
      [t]
    }
  }

  let child_tools = case model.child_ids {
    [] -> []
    _ -> {
      let assert Ok(t) =
        tool.new(
          name: "send_to_child",
          description: "Send a message to one of your child agents.",
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
                    #(
                      "description",
                      json.string("The message content to send."),
                    ),
                  ]),
                ),
              ]),
            ),
            #("required", json.array(["child_id", "message"], json.string)),
            #("additionalProperties", json.bool(False)),
          ]),
        )
      [t]
    }
  }

  let assert Ok(read_tool) =
    tool.new(
      name: "read_mailbox",
      description: "Read all messages in your mailbox inbox.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(unread_tool) =
    tool.new(
      name: "check_unread",
      description: "Check for unread messages in your mailbox.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  list.flatten([parent_tools, child_tools, [read_tool, unread_tool]])
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
    "send_to_parent" -> {
      case decode.run(args, decode.at(["message"], decode.string)) {
        Ok(content) -> Ok(SendToParent(content: content, initiator: LLM))
        Error(_) -> Error("send_to_parent: missing 'message' field")
      }
    }
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
    "read_mailbox" -> Ok(ReadMailbox(initiator: LLM))
    "check_unread" -> Ok(CheckUnread(initiator: LLM))
    _ -> Error("Mailbox: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: MailboxModel,
  event_name: String,
  args: Dynamic,
) -> Option(MailboxMsg) {
  case event_name {
    "send_to_parent" ->
      case decode.run(args, decode.at(["message"], decode.string)) {
        Ok(content) -> Some(SendToParent(content: content, initiator: UI))
        Error(_) -> None
      }
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
    "read_mailbox" -> Some(ReadMailbox(initiator: UI))
    "check_unread" -> Some(CheckUnread(initiator: UI))
    _ -> None
  }
}

// ============================================================================
// Helpers
// ============================================================================

fn format_inbox(messages: List(MailMessage)) -> String {
  case messages {
    [] -> "Mailbox is empty."
    _ ->
      "Inbox ("
      <> int.to_string(list.length(messages))
      <> " messages):\n"
      <> format_message_list(messages)
  }
}

fn format_message_list(messages: List(MailMessage)) -> String {
  list.map(messages, fn(m) {
    let read_marker = case m.read {
      True -> ""
      False -> " [UNREAD]"
    }
    "- From "
    <> m.from
    <> ": \""
    <> m.content
    <> "\""
    <> read_marker
  })
  |> string.join("\n")
}

// ============================================================================
// Factory
// ============================================================================

/// Create a mailbox widget for an agent.
pub fn create(
  agent_id agent_id: String,
  parent_id parent_id: Option(String),
  child_ids child_ids: List(String),
  broker broker: Subject(MailboxBrokerMessage),
) -> WidgetHandle {
  let all_tools = ["read_mailbox", "check_unread", "send_to_parent", "send_to_child"]
  widget.create(widget.WidgetConfig(
    id: "mailbox",
    model: MailboxModel(
      agent_id: agent_id,
      parent_id: parent_id,
      child_ids: child_ids,
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

/// Add a child ID to the mailbox widget's child_ids list.
/// Returns the updated model (for use when a child is spawned at runtime).
pub fn add_child(model: MailboxModel, child_id: String) -> MailboxModel {
  MailboxModel(..model, child_ids: list.append(model.child_ids, [child_id]))
}
