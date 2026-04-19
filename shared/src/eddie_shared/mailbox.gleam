/// Mailbox message type for parent-child agent communication.
///
/// Messages are free-form text, routed by agent ID.
import gleam/dynamic/decode
import gleam/json

// ============================================================================
// Types
// ============================================================================

/// A single message in an agent's mailbox.
pub type MailMessage {
  MailMessage(
    /// Unique message identifier.
    id: String,
    /// Sender agent ID.
    from: String,
    /// Recipient agent ID.
    to: String,
    /// Free-form message content.
    content: String,
    /// Epoch milliseconds when the message was sent.
    timestamp: Int,
    /// Whether the recipient has read this message.
    read: Bool,
  )
}

// ============================================================================
// JSON encoding
// ============================================================================

pub fn mail_message_to_json(msg: MailMessage) -> json.Json {
  json.object([
    #("id", json.string(msg.id)),
    #("from", json.string(msg.from)),
    #("to", json.string(msg.to)),
    #("content", json.string(msg.content)),
    #("timestamp", json.int(msg.timestamp)),
    #("read", json.bool(msg.read)),
  ])
}

// ============================================================================
// JSON decoding
// ============================================================================

pub fn mail_message_decoder() -> decode.Decoder(MailMessage) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use content <- decode.field("content", decode.string)
  use timestamp <- decode.field("timestamp", decode.int)
  use read <- decode.field("read", decode.bool)
  decode.success(MailMessage(id:, from:, to:, content:, timestamp:, read:))
}
