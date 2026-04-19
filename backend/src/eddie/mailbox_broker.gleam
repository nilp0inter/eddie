/// Mailbox broker — central OTP actor for routing messages between agents.
///
/// All agents share a single broker. It stores inboxes and outboxes,
/// tracks read/unread state, and notifies subscribers when new mail arrives.
import gleam/dict.{type Dict}
import gleam/int
import gleam/list

import eddie_shared/mailbox.{type MailMessage, MailMessage}

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

// ============================================================================
// Types
// ============================================================================

/// Messages handled by the mailbox broker actor.
pub opaque type MailboxBrokerMessage {
  SendMail(
    from: String,
    to: String,
    content: String,
    reply_to: Subject(Result(MailMessage, String)),
  )
  ReadMail(agent_id: String, reply_to: Subject(List(MailMessage)))
  ReadUnread(agent_id: String, reply_to: Subject(List(MailMessage)))
  MarkRead(
    agent_id: String,
    message_id: String,
    reply_to: Subject(Result(Nil, String)),
  )
  GetOutbox(agent_id: String, reply_to: Subject(List(MailMessage)))
  SubscribeMailbox(agent_id: String, subscriber: Subject(MailMessage))
  UnsubscribeMailbox(agent_id: String, subscriber: Subject(MailMessage))
}

/// Internal actor state.
type BrokerState {
  BrokerState(
    /// agent_id -> inbox (newest first)
    mailboxes: Dict(String, List(MailMessage)),
    /// agent_id -> sent messages (newest first)
    outboxes: Dict(String, List(MailMessage)),
    /// agent_id -> subscribers notified on new mail
    subscribers: Dict(String, List(Subject(MailMessage))),
    /// Counter for generating unique message IDs
    next_id: Int,
  )
}

// ============================================================================
// Start
// ============================================================================

/// Start a new mailbox broker actor.
pub fn start() -> Result(Subject(MailboxBrokerMessage), actor.StartError) {
  let initial_state =
    BrokerState(
      mailboxes: dict.new(),
      outboxes: dict.new(),
      subscribers: dict.new(),
      next_id: 1,
    )
  let result =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

// ============================================================================
// Message handler
// ============================================================================

fn handle_message(
  state: BrokerState,
  msg: MailboxBrokerMessage,
) -> actor.Next(BrokerState, MailboxBrokerMessage) {
  case msg {
    SendMail(from, to, content, reply_to) -> {
      let msg_id = "mail-" <> int.to_string(state.next_id)
      let timestamp = now_millis()
      let mail =
        MailMessage(
          id: msg_id,
          from: from,
          to: to,
          content: content,
          timestamp: timestamp,
          read: False,
        )
      // Append to recipient's inbox
      let inbox = dict.get(state.mailboxes, to) |> unwrap_list
      let new_mailboxes = dict.insert(state.mailboxes, to, [mail, ..inbox])
      // Append to sender's outbox
      let outbox = dict.get(state.outboxes, from) |> unwrap_list
      let new_outboxes = dict.insert(state.outboxes, from, [mail, ..outbox])
      // Notify subscribers for the recipient
      let subs = dict.get(state.subscribers, to) |> unwrap_list
      list.each(subs, fn(sub) { process.send(sub, mail) })

      process.send(reply_to, Ok(mail))
      actor.continue(
        BrokerState(
          ..state,
          mailboxes: new_mailboxes,
          outboxes: new_outboxes,
          next_id: state.next_id + 1,
        ),
      )
    }

    ReadMail(agent_id, reply_to) -> {
      let inbox = dict.get(state.mailboxes, agent_id) |> unwrap_list
      process.send(reply_to, list.reverse(inbox))
      actor.continue(state)
    }

    ReadUnread(agent_id, reply_to) -> {
      let inbox = dict.get(state.mailboxes, agent_id) |> unwrap_list
      let unread = list.filter(inbox, fn(m) { !m.read })
      process.send(reply_to, list.reverse(unread))
      actor.continue(state)
    }

    MarkRead(agent_id, message_id, reply_to) -> {
      let inbox = dict.get(state.mailboxes, agent_id) |> unwrap_list
      let #(found, updated) =
        list.fold(inbox, #(False, []), fn(acc, m) {
          case m.id == message_id {
            True -> #(True, [MailMessage(..m, read: True), ..acc.1])
            False -> #(acc.0, [m, ..acc.1])
          }
        })
      case found {
        False -> {
          process.send(reply_to, Error("Message not found: " <> message_id))
          actor.continue(state)
        }
        True -> {
          let new_mailboxes =
            dict.insert(state.mailboxes, agent_id, list.reverse(updated))
          process.send(reply_to, Ok(Nil))
          actor.continue(BrokerState(..state, mailboxes: new_mailboxes))
        }
      }
    }

    GetOutbox(agent_id, reply_to) -> {
      let outbox = dict.get(state.outboxes, agent_id) |> unwrap_list
      process.send(reply_to, list.reverse(outbox))
      actor.continue(state)
    }

    SubscribeMailbox(agent_id, subscriber) -> {
      let subs = dict.get(state.subscribers, agent_id) |> unwrap_list
      let new_subs =
        dict.insert(state.subscribers, agent_id, [subscriber, ..subs])
      actor.continue(BrokerState(..state, subscribers: new_subs))
    }

    UnsubscribeMailbox(agent_id, subscriber) -> {
      let subs = dict.get(state.subscribers, agent_id) |> unwrap_list
      let filtered = list.filter(subs, fn(s) { s != subscriber })
      let new_subs = dict.insert(state.subscribers, agent_id, filtered)
      actor.continue(BrokerState(..state, subscribers: new_subs))
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Send a message from one agent to another.
pub fn send_mail(
  broker broker: Subject(MailboxBrokerMessage),
  from from: String,
  to to: String,
  content content: String,
) -> Result(MailMessage, String) {
  process.call(broker, waiting: 5000, sending: fn(reply_to) {
    SendMail(from:, to:, content:, reply_to:)
  })
}

/// Read all messages in an agent's inbox (chronological order).
pub fn read_mail(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
) -> List(MailMessage) {
  process.call(broker, waiting: 5000, sending: fn(reply_to) {
    ReadMail(agent_id:, reply_to:)
  })
}

/// Read only unread messages in an agent's inbox.
pub fn read_unread(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
) -> List(MailMessage) {
  process.call(broker, waiting: 5000, sending: fn(reply_to) {
    ReadUnread(agent_id:, reply_to:)
  })
}

/// Mark a message as read.
pub fn mark_read(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
  message_id message_id: String,
) -> Result(Nil, String) {
  process.call(broker, waiting: 5000, sending: fn(reply_to) {
    MarkRead(agent_id:, message_id:, reply_to:)
  })
}

/// Get all messages sent by an agent (chronological order).
pub fn get_outbox(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
) -> List(MailMessage) {
  process.call(broker, waiting: 5000, sending: fn(reply_to) {
    GetOutbox(agent_id:, reply_to:)
  })
}

/// Subscribe to new mail notifications for a specific agent.
pub fn subscribe_mailbox(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
  subscriber subscriber: Subject(MailMessage),
) -> Nil {
  process.send(broker, SubscribeMailbox(agent_id:, subscriber:))
}

/// Unsubscribe from mail notifications.
pub fn unsubscribe_mailbox(
  broker broker: Subject(MailboxBrokerMessage),
  agent_id agent_id: String,
  subscriber subscriber: Subject(MailMessage),
) -> Nil {
  process.send(broker, UnsubscribeMailbox(agent_id:, subscriber:))
}

// ============================================================================
// Helpers
// ============================================================================

fn unwrap_list(result: Result(List(a), b)) -> List(a) {
  case result {
    Ok(list) -> list
    Error(_) -> []
  }
}

@external(erlang, "eddie_ffi", "now_millis")
fn now_millis() -> Int
