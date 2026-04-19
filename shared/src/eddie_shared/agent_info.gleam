/// Agent metadata types for the rose-tree agent hierarchy.
///
/// AgentInfo describes an agent's identity and current status.
/// AgentTreeNode represents a node in the rose-tree forest.
/// AgentStatus tracks whether an agent is idle, running, etc.
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

// ============================================================================
// Types
// ============================================================================

/// The current execution status of an agent.
pub type AgentStatus {
  /// Agent exists but is not processing a turn.
  AgentIdle
  /// Agent is currently processing a turn (LLM in flight or effects pending).
  AgentRunning
  /// Agent finished its work successfully.
  AgentCompleted
  /// Agent encountered an unrecoverable error.
  AgentError
}

/// Information about an available agent.
pub type AgentInfo {
  AgentInfo(
    id: String,
    label: String,
    parent_id: Option(String),
    status: AgentStatus,
  )
}

/// A node in the agent rose-tree. Each node has an AgentInfo and
/// a list of child nodes (which may be empty for leaf agents).
pub type AgentTreeNode {
  AgentTreeNode(info: AgentInfo, children: List(AgentTreeNode))
}

// ============================================================================
// AgentStatus helpers
// ============================================================================

pub fn status_to_string(status: AgentStatus) -> String {
  case status {
    AgentIdle -> "idle"
    AgentRunning -> "running"
    AgentCompleted -> "completed"
    AgentError -> "error"
  }
}

pub fn parse_status(text: String) -> Result(AgentStatus, Nil) {
  case text {
    "idle" -> Ok(AgentIdle)
    "running" -> Ok(AgentRunning)
    "completed" -> Ok(AgentCompleted)
    "error" -> Ok(AgentError)
    _ -> Error(Nil)
  }
}

// ============================================================================
// JSON encoding
// ============================================================================

pub fn status_to_json(status: AgentStatus) -> json.Json {
  json.string(status_to_string(status))
}

pub fn agent_info_to_json(info: AgentInfo) -> json.Json {
  json.object([
    #("id", json.string(info.id)),
    #("label", json.string(info.label)),
    #("parent_id", case info.parent_id {
      Some(pid) -> json.string(pid)
      None -> json.null()
    }),
    #("status", status_to_json(info.status)),
  ])
}

pub fn agent_tree_node_to_json(node: AgentTreeNode) -> json.Json {
  json.object([
    #("info", agent_info_to_json(node.info)),
    #("children", json.array(node.children, agent_tree_node_to_json)),
  ])
}

// ============================================================================
// JSON decoding
// ============================================================================

pub fn status_decoder() -> decode.Decoder(AgentStatus) {
  use text <- decode.then(decode.string)
  case parse_status(text) {
    Ok(status) -> decode.success(status)
    Error(_) -> decode.failure(AgentIdle, "AgentStatus")
  }
}

pub fn agent_info_decoder() -> decode.Decoder(AgentInfo) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  use parent_id <- decode.field("parent_id", decode.optional(decode.string))
  use status <- decode.field("status", status_decoder())
  decode.success(AgentInfo(id:, label:, parent_id:, status:))
}

pub fn agent_tree_node_decoder() -> decode.Decoder(AgentTreeNode) {
  use info <- decode.field("info", agent_info_decoder())
  use children <- decode.field(
    "children",
    decode.list(agent_tree_node_decoder()),
  )
  decode.success(AgentTreeNode(info:, children:))
}
