/// Agent tree — manages hierarchical parent-child agent relationships.
///
/// Each agent in the tree is an independent OTP actor with its own context.
/// Children inherit the parent's LlmConfig (with optional overrides) and
/// run their own turn loops independently.
///
/// The tree itself is an OTP actor so children can be spawned at runtime
/// and looked up by the server without holding a stale reference.
import gleam/dict.{type Dict}
import gleam/list
import gleam/result

import eddie/agent.{
  type AgentConfig, type AgentConfigOverride, type AgentMessage,
}
import eddie/http as eddie_http

import eddie_shared/protocol.{type AgentInfo, AgentInfo}

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

/// Messages handled by the agent tree actor.
pub opaque type AgentTreeMessage {
  GetRoot(reply_to: Subject(Subject(AgentMessage)))
  GetAgent(id: String, reply_to: Subject(Result(Subject(AgentMessage), Nil)))
  ListAgents(reply_to: Subject(List(AgentInfo)))
  SpawnChild(
    id: String,
    label: String,
    override: AgentConfigOverride,
    reply_to: Subject(Result(Nil, SpawnError)),
  )
}

/// Internal actor state.
type TreeState {
  TreeState(
    root: Subject(AgentMessage),
    root_config: AgentConfig,
    children: Dict(String, #(Subject(AgentMessage), String)),
    send_fn: fn(Request(String)) ->
      Result(Response(String), eddie_http.HttpError),
  )
}

/// Start a new agent tree with a root agent.
pub fn start(
  config config: AgentConfig,
) -> Result(Subject(AgentTreeMessage), actor.StartError) {
  start_with_send_fn(config: config, send_fn: eddie_http.send)
}

/// Start a new agent tree with an injectable HTTP send function (for testing).
pub fn start_with_send_fn(
  config config: AgentConfig,
  send_fn send_fn: fn(Request(String)) ->
    Result(Response(String), eddie_http.HttpError),
) -> Result(Subject(AgentTreeMessage), actor.StartError) {
  use root <- result.try(agent.start_with_send_fn(
    config: config,
    send_fn: send_fn,
  ))
  let initial_state =
    TreeState(
      root: root,
      root_config: config,
      children: dict.new(),
      send_fn: send_fn,
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

fn handle_message(
  state: TreeState,
  msg: AgentTreeMessage,
) -> actor.Next(TreeState, AgentTreeMessage) {
  case msg {
    GetRoot(reply_to) -> {
      process.send(reply_to, state.root)
      actor.continue(state)
    }

    GetAgent(id, reply_to) -> {
      let result = case id {
        "root" -> Ok(state.root)
        _ ->
          dict.get(state.children, id)
          |> result.map(fn(pair) { pair.0 })
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    ListAgents(reply_to) -> {
      let root_info = AgentInfo(id: "root", label: "Root")
      let child_infos =
        dict.to_list(state.children)
        |> list.map(fn(entry) {
          let #(id, #(_, label)) = entry
          AgentInfo(id: id, label: label)
        })
      process.send(reply_to, [root_info, ..child_infos])
      actor.continue(state)
    }

    SpawnChild(id, label, override, reply_to) -> {
      case dict.has_key(state.children, id) {
        True -> {
          process.send(reply_to, Error(ChildAlreadyExists(id: id)))
          actor.continue(state)
        }
        False -> {
          let child_config =
            agent.merge_config(
              parent: state.root_config,
              child_id: id,
              override: override,
            )
          case
            agent.start_with_send_fn(
              config: child_config,
              send_fn: state.send_fn,
            )
          {
            Error(err) -> {
              process.send(reply_to, Error(ChildStartFailed(err)))
              actor.continue(state)
            }
            Ok(child_subject) -> {
              let new_children =
                dict.insert(state.children, id, #(child_subject, label))
              process.send(reply_to, Ok(Nil))
              actor.continue(TreeState(..state, children: new_children))
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Public API — callers interact via typed functions, never raw messages
// ============================================================================

/// Get the root agent's subject.
pub fn root(tree tree: Subject(AgentTreeMessage)) -> Subject(AgentMessage) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) { GetRoot(reply_to:) })
}

/// Look up an agent by ID. "root" returns the root agent.
pub fn get_agent(
  tree tree: Subject(AgentTreeMessage),
  id id: String,
) -> Result(Subject(AgentMessage), Nil) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    GetAgent(id:, reply_to:)
  })
}

/// List all available agents (root + children).
pub fn list_agents(tree tree: Subject(AgentTreeMessage)) -> List(AgentInfo) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    ListAgents(reply_to:)
  })
}

/// Spawn a child agent with the given ID, label, and config override.
pub fn spawn_child(
  tree tree: Subject(AgentTreeMessage),
  id id: String,
  label label: String,
  override override: AgentConfigOverride,
) -> Result(Nil, SpawnError) {
  process.call(tree, waiting: 10_000, sending: fn(reply_to) {
    SpawnChild(id:, label:, override:, reply_to:)
  })
}
