/// Agent tree — manages hierarchical parent-child agent relationships.
///
/// Each agent in the tree is an independent OTP actor with its own context.
/// Children inherit the parent's LlmConfig (with optional overrides) and
/// run their own turn loops independently.
import gleam/dict.{type Dict}
import gleam/result

import eddie/agent.{
  type AgentConfig, type AgentConfigOverride, type AgentMessage,
}
import eddie/http as eddie_http

import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/otp/actor

/// Errors that can occur when spawning a child agent.
pub type SpawnError {
  /// A child with this ID already exists
  ChildAlreadyExists(id: String)
  /// The agent actor failed to start
  ChildStartFailed(actor.StartError)
}

/// A tree of agent actors with a root and named children.
pub opaque type AgentTree {
  AgentTree(
    root: Subject(AgentMessage),
    root_config: AgentConfig,
    children: Dict(String, Subject(AgentMessage)),
    send_fn: fn(Request(String)) ->
      Result(Response(String), eddie_http.HttpError),
  )
}

/// Start a new agent tree with a root agent.
pub fn start(config config: AgentConfig) -> Result(AgentTree, actor.StartError) {
  start_with_send_fn(config: config, send_fn: eddie_http.send)
}

/// Start a new agent tree with an injectable HTTP send function (for testing).
pub fn start_with_send_fn(
  config config: AgentConfig,
  send_fn send_fn: fn(Request(String)) ->
    Result(Response(String), eddie_http.HttpError),
) -> Result(AgentTree, actor.StartError) {
  use root <- result.try(agent.start_with_send_fn(
    config: config,
    send_fn: send_fn,
  ))
  Ok(AgentTree(
    root: root,
    root_config: config,
    children: dict.new(),
    send_fn: send_fn,
  ))
}

/// Get the root agent's subject.
pub fn root(tree tree: AgentTree) -> Subject(AgentMessage) {
  tree.root
}

/// Spawn a child agent with the given ID and config override.
/// The child inherits the root's config, with overrides applied.
pub fn spawn_child(
  tree tree: AgentTree,
  id id: String,
  override override: AgentConfigOverride,
) -> Result(AgentTree, SpawnError) {
  case dict.has_key(tree.children, id) {
    True -> Error(ChildAlreadyExists(id: id))
    False -> {
      let child_config =
        agent.merge_config(parent: tree.root_config, override: override)
      case
        agent.start_with_send_fn(config: child_config, send_fn: tree.send_fn)
      {
        Error(err) -> Error(ChildStartFailed(err))
        Ok(child_subject) -> {
          let new_children = dict.insert(tree.children, id, child_subject)
          Ok(AgentTree(..tree, children: new_children))
        }
      }
    }
  }
}

/// Get a child agent's subject by ID.
pub fn get_child(
  tree tree: AgentTree,
  id id: String,
) -> Result(Subject(AgentMessage), Nil) {
  dict.get(tree.children, id)
}

/// Get all child agent subjects.
pub fn children(tree tree: AgentTree) -> Dict(String, Subject(AgentMessage)) {
  tree.children
}
