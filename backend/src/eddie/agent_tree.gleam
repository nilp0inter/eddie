/// Agent tree — manages a forest of rose-tree agent hierarchies.
///
/// Each agent in the tree is an independent OTP actor with its own context.
/// Children inherit the parent's LlmConfig (with optional overrides) and
/// run their own turn loops independently.
///
/// The tree starts empty — no agents exist until explicitly spawned.
/// Root agents are created by the user via the UI. Child agents are
/// spawned by parent agents via tools.
///
/// The tree itself is an OTP actor so agents can be spawned at runtime
/// and looked up by the server without holding a stale reference.
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}

import eddie/agent.{
  type AgentConfig, type AgentConfigOverride, type AgentMessage, AgentConfig,
}
import eddie/http as eddie_http
import eddie/mailbox_broker.{type MailboxBrokerMessage}
import eddie/widgets/mailbox as eddie_mailbox
import eddie/widgets/subagent_manager as eddie_subagent_manager

import eddie_shared/agent_info.{
  type AgentInfo, type AgentStatus, type AgentTreeNode, AgentInfo, AgentTreeNode,
}
import eddie_shared/protocol

import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/otp/actor

/// Errors that can occur when spawning an agent.
pub type SpawnError {
  /// An agent with this ID already exists.
  AgentAlreadyExists(id: String)
  /// The specified parent does not exist.
  ParentNotFound(id: String)
  /// The agent actor failed to start.
  AgentStartFailed(actor.StartError)
}

/// An entry in the flat agent registry.
type AgentEntry {
  AgentEntry(
    subject: Subject(AgentMessage),
    label: String,
    parent_id: Option(String),
    child_ids: List(String),
    status: AgentStatus,
  )
}

/// Messages handled by the agent tree actor.
pub opaque type AgentTreeMessage {
  GetAgent(id: String, reply_to: Subject(Result(Subject(AgentMessage), Nil)))
  GetAgentTree(reply_to: Subject(List(AgentTreeNode)))
  GetChildren(parent_id: String, reply_to: Subject(List(AgentInfo)))
  GetParent(child_id: String, reply_to: Subject(Option(String)))
  SpawnRootAgent(
    id: String,
    label: String,
    system_prompt: String,
    reply_to: Subject(Result(Nil, SpawnError)),
  )
  SpawnChildAgent(
    id: String,
    label: String,
    parent_id: String,
    goal: String,
    initial_message: String,
    override: AgentConfigOverride,
    reply_to: Subject(Result(Nil, SpawnError)),
  )
  UpdateStatus(agent_id: String, status: AgentStatus)
  SubscribeTree(subscriber: Subject(String))
  UnsubscribeTree(subscriber: Subject(String))
  SetSelf(subject: Subject(AgentTreeMessage))
  SetBroker(broker: Subject(MailboxBrokerMessage))
}

/// Internal actor state.
type TreeState {
  TreeState(
    agents: Dict(String, AgentEntry),
    base_config: AgentConfig,
    send_fn: fn(Request(String)) ->
      Result(Response(String), eddie_http.HttpError),
    subscribers: List(Subject(String)),
    self: Option(Subject(AgentTreeMessage)),
    broker: Option(Subject(MailboxBrokerMessage)),
  )
}

/// Start a new empty agent tree.
pub fn start(
  config config: AgentConfig,
) -> Result(Subject(AgentTreeMessage), actor.StartError) {
  start_with_send_fn(config: config, send_fn: eddie_http.send)
}

/// Start an empty agent tree with an injectable HTTP send function (for testing).
pub fn start_with_send_fn(
  config config: AgentConfig,
  send_fn send_fn: fn(Request(String)) ->
    Result(Response(String), eddie_http.HttpError),
) -> Result(Subject(AgentTreeMessage), actor.StartError) {
  let initial_state =
    TreeState(
      agents: dict.new(),
      base_config: config,
      send_fn: send_fn,
      subscribers: [],
      self: None,
      broker: None,
    )
  let result =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> {
      process.send(started.data, SetSelf(subject: started.data))
      Ok(started.data)
    }
    Error(err) -> Error(err)
  }
}

fn handle_message(
  state: TreeState,
  msg: AgentTreeMessage,
) -> actor.Next(TreeState, AgentTreeMessage) {
  case msg {
    SetSelf(subject) ->
      actor.continue(TreeState(..state, self: Some(subject)))

    SetBroker(broker) ->
      actor.continue(TreeState(..state, broker: Some(broker)))

    GetAgent(id, reply_to) -> {
      let result = case dict.get(state.agents, id) {
        Ok(entry) -> Ok(entry.subject)
        Error(_) -> Error(Nil)
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetAgentTree(reply_to) -> {
      process.send(reply_to, build_tree(state.agents))
      actor.continue(state)
    }

    GetChildren(parent_id, reply_to) -> {
      let children = case dict.get(state.agents, parent_id) {
        Ok(entry) ->
          list.filter_map(entry.child_ids, fn(cid) {
            case dict.get(state.agents, cid) {
              Ok(child) ->
                Ok(AgentInfo(
                  id: cid,
                  label: child.label,
                  parent_id: Some(parent_id),
                  status: child.status,
                ))
              Error(_) -> Error(Nil)
            }
          })
        Error(_) -> []
      }
      process.send(reply_to, children)
      actor.continue(state)
    }

    GetParent(child_id, reply_to) -> {
      let parent = case dict.get(state.agents, child_id) {
        Ok(entry) -> entry.parent_id
        Error(_) -> None
      }
      process.send(reply_to, parent)
      actor.continue(state)
    }

    SpawnRootAgent(id, label, system_prompt, reply_to) -> {
      case dict.has_key(state.agents, id) {
        True -> {
          process.send(reply_to, Error(AgentAlreadyExists(id: id)))
          actor.continue(state)
        }
        False -> {
          let extra = build_extra_widgets(
            agent_id: id,
            parent_id: None,
            tree_self: state.self,
            broker: state.broker,
          )
          let config =
            AgentConfig(
              ..state.base_config,
              agent_id: id,
              system_prompt: system_prompt,
              extra_widgets: extra,
            )
          case agent.start_with_send_fn(config: config, send_fn: state.send_fn) {
            Error(err) -> {
              process.send(reply_to, Error(AgentStartFailed(err)))
              actor.continue(state)
            }
            Ok(subject) -> {
              let entry =
                AgentEntry(
                  subject: subject,
                  label: label,
                  parent_id: None,
                  child_ids: [],
                  status: agent_info.AgentIdle,
                )
              let new_agents = dict.insert(state.agents, id, entry)
              let new_state = TreeState(..state, agents: new_agents)
              process.send(reply_to, Ok(Nil))
              broadcast_tree_changed(new_state)
              actor.continue(new_state)
            }
          }
        }
      }
    }

    SpawnChildAgent(id, label, parent_id, _goal, initial_message, override, reply_to) -> {
      case dict.has_key(state.agents, id) {
        True -> {
          process.send(reply_to, Error(AgentAlreadyExists(id: id)))
          actor.continue(state)
        }
        False -> {
          case dict.get(state.agents, parent_id) {
            Error(_) -> {
              process.send(reply_to, Error(ParentNotFound(id: parent_id)))
              actor.continue(state)
            }
            Ok(parent_entry) -> {
              let extra = build_extra_widgets(
                agent_id: id,
                parent_id: Some(parent_id),
                tree_self: state.self,
                broker: state.broker,
              )
              let child_config =
                AgentConfig(
                  ..agent.merge_config(
                    parent: state.base_config,
                    child_id: id,
                    override: override,
                  ),
                  extra_widgets: extra,
                )
              case
                agent.start_with_send_fn(
                  config: child_config,
                  send_fn: state.send_fn,
                )
              {
                Error(err) -> {
                  process.send(reply_to, Error(AgentStartFailed(err)))
                  actor.continue(state)
                }
                Ok(child_subject) -> {
                  let child_entry =
                    AgentEntry(
                      subject: child_subject,
                      label: label,
                      parent_id: Some(parent_id),
                      child_ids: [],
                      status: agent_info.AgentIdle,
                    )
                  let updated_parent =
                    AgentEntry(
                      ..parent_entry,
                      child_ids: list.append(parent_entry.child_ids, [id]),
                    )
                  let new_agents =
                    state.agents
                    |> dict.insert(id, child_entry)
                    |> dict.insert(parent_id, updated_parent)
                  let new_state = TreeState(..state, agents: new_agents)
                  process.send(reply_to, Ok(Nil))
                  // Send the initial message to start the child's turn
                  agent.send_message(subject: child_subject, text: initial_message)
                  broadcast_tree_changed(new_state)
                  actor.continue(new_state)
                }
              }
            }
          }
        }
      }
    }

    UpdateStatus(agent_id, status) -> {
      case dict.get(state.agents, agent_id) {
        Error(_) -> actor.continue(state)
        Ok(entry) -> {
          let updated = AgentEntry(..entry, status: status)
          let new_agents = dict.insert(state.agents, agent_id, updated)
          let new_state = TreeState(..state, agents: new_agents)
          broadcast_tree_changed(new_state)
          actor.continue(new_state)
        }
      }
    }

    SubscribeTree(subscriber) -> {
      actor.continue(
        TreeState(..state, subscribers: [subscriber, ..state.subscribers]),
      )
    }

    UnsubscribeTree(subscriber) -> {
      actor.continue(
        TreeState(
          ..state,
          subscribers: list.filter(state.subscribers, fn(s) { s != subscriber }),
        ),
      )
    }
  }
}

// ============================================================================
// Extra widget construction
// ============================================================================

import eddie/widget.{type WidgetHandle}

/// Build extra widgets for an agent based on its position in the tree.
fn build_extra_widgets(
  agent_id agent_id: String,
  parent_id parent_id: Option(String),
  tree_self tree_self: Option(Subject(AgentTreeMessage)),
  broker broker: Option(Subject(MailboxBrokerMessage)),
) -> List(WidgetHandle) {
  let subagent_widgets = case tree_self {
    Some(tree) -> {
      let aid = agent_id
      let spawn_fn = fn(child_id, label, goal, initial_message, system_prompt) {
        let override =
          agent.AgentConfigOverride(
            model: None,
            api_base: None,
            system_prompt: Some(system_prompt),
          )
        case
          spawn_child(
            tree: tree,
            id: child_id,
            label: label,
            parent_id: aid,
            goal: goal,
            initial_message: initial_message,
            override: override,
          )
        {
          Ok(_) -> Ok(Nil)
          Error(AgentAlreadyExists(id)) ->
            Error("Agent '" <> id <> "' already exists")
          Error(ParentNotFound(id)) ->
            Error("Parent '" <> id <> "' not found")
          Error(AgentStartFailed(_)) -> Error("Failed to start agent")
        }
      }
      let list_fn = fn() { get_children(tree: tree, parent_id: aid) }
      [
        eddie_subagent_manager.create(
          agent_id: agent_id,
          spawn_fn: spawn_fn,
          list_children_fn: list_fn,
        ),
      ]
    }
    None -> []
  }
  let mailbox_widgets = case broker, tree_self {
    Some(b), Some(tree) -> {
      let aid = agent_id
      let list_fn = fn() { get_children(tree: tree, parent_id: aid) }
      [
        eddie_mailbox.create(
          agent_id: agent_id,
          parent_id: parent_id,
          list_children_fn: list_fn,
          broker: b,
        ),
      ]
    }
    Some(b), None -> {
      let list_fn = fn() { [] }
      [
        eddie_mailbox.create(
          agent_id: agent_id,
          parent_id: parent_id,
          list_children_fn: list_fn,
          broker: b,
        ),
      ]
    }
    _, _ -> []
  }
  list.append(subagent_widgets, mailbox_widgets)
}

// ============================================================================
// Tree building — assemble rose-tree from flat Dict
// ============================================================================

/// Build the rose-tree forest from the flat agent registry.
/// Returns only root nodes (agents with no parent), with children nested.
fn build_tree(agents: Dict(String, AgentEntry)) -> List(AgentTreeNode) {
  dict.to_list(agents)
  |> list.filter(fn(pair) { { pair.1 }.parent_id == None })
  |> list.map(fn(pair) { build_node(pair.0, pair.1, agents) })
}

fn build_node(
  id: String,
  entry: AgentEntry,
  agents: Dict(String, AgentEntry),
) -> AgentTreeNode {
  let info =
    AgentInfo(
      id: id,
      label: entry.label,
      parent_id: entry.parent_id,
      status: entry.status,
    )
  let children =
    list.filter_map(entry.child_ids, fn(cid) {
      case dict.get(agents, cid) {
        Ok(child_entry) -> Ok(build_node(cid, child_entry, agents))
        Error(_) -> Error(Nil)
      }
    })
  AgentTreeNode(info: info, children: children)
}

// ============================================================================
// Subscriber notification
// ============================================================================

fn broadcast_tree_changed(state: TreeState) -> Nil {
  case state.subscribers {
    [] -> Nil
    _ -> {
      let tree = build_tree(state.agents)
      let event = protocol.AgentTreeChanged(roots: tree)
      let payload = protocol.server_events_to_json_string([event])
      list.each(state.subscribers, fn(sub) { process.send(sub, payload) })
    }
  }
}

// ============================================================================
// Public API — callers interact via typed functions, never raw messages
// ============================================================================

/// Look up an agent by ID.
pub fn get_agent(
  tree tree: Subject(AgentTreeMessage),
  id id: String,
) -> Result(Subject(AgentMessage), Nil) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    GetAgent(id:, reply_to:)
  })
}

/// Get the full rose-tree forest of all agents.
pub fn get_tree(
  tree tree: Subject(AgentTreeMessage),
) -> List(AgentTreeNode) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    GetAgentTree(reply_to:)
  })
}

/// Get the children of a specific agent.
pub fn get_children(
  tree tree: Subject(AgentTreeMessage),
  parent_id parent_id: String,
) -> List(AgentInfo) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    GetChildren(parent_id:, reply_to:)
  })
}

/// Get the parent ID of a specific agent.
pub fn get_parent(
  tree tree: Subject(AgentTreeMessage),
  child_id child_id: String,
) -> Option(String) {
  process.call(tree, waiting: 5000, sending: fn(reply_to) {
    GetParent(child_id:, reply_to:)
  })
}

/// Spawn a new root agent (top-level, no parent).
pub fn spawn_root(
  tree tree: Subject(AgentTreeMessage),
  id id: String,
  label label: String,
  system_prompt system_prompt: String,
) -> Result(Nil, SpawnError) {
  process.call(tree, waiting: 10_000, sending: fn(reply_to) {
    SpawnRootAgent(id:, label:, system_prompt:, reply_to:)
  })
}

/// Spawn a child agent under a parent.
pub fn spawn_child(
  tree tree: Subject(AgentTreeMessage),
  id id: String,
  label label: String,
  parent_id parent_id: String,
  goal goal: String,
  initial_message initial_message: String,
  override override: AgentConfigOverride,
) -> Result(Nil, SpawnError) {
  process.call(tree, waiting: 10_000, sending: fn(reply_to) {
    SpawnChildAgent(id:, label:, parent_id:, goal:, initial_message:, override:, reply_to:)
  })
}

/// Update an agent's status.
pub fn update_status(
  tree tree: Subject(AgentTreeMessage),
  agent_id agent_id: String,
  status status: AgentStatus,
) -> Nil {
  process.send(tree, UpdateStatus(agent_id:, status:))
}

/// Subscribe to tree change events (for control WebSocket).
pub fn subscribe_tree(
  tree tree: Subject(AgentTreeMessage),
  subscriber subscriber: Subject(String),
) -> Nil {
  process.send(tree, SubscribeTree(subscriber:))
}

/// Unsubscribe from tree change events.
pub fn unsubscribe_tree(
  tree tree: Subject(AgentTreeMessage),
  subscriber subscriber: Subject(String),
) -> Nil {
  process.send(tree, UnsubscribeTree(subscriber:))
}

/// Set the mailbox broker on the tree (called once at startup).
pub fn set_broker(
  tree tree: Subject(AgentTreeMessage),
  broker broker: Subject(MailboxBrokerMessage),
) -> Nil {
  process.send(tree, SetBroker(broker:))
}
