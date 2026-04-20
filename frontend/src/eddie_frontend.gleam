/// Eddie frontend — Lustre SPA.
///
/// Two-page application:
/// - AgentListPage: landing page showing the agent forest, "+" creates root agents
/// - AgentConversationPage: chat UI for a specific agent with sidebar panels
///
/// Two WebSocket connections:
/// - Control WS (/ws/control): always connected, receives tree changes, sends SpawnRootAgent
/// - Agent WS (/ws/<id>): connected only when viewing a conversation
import eddie_shared/agent_info.{type AgentInfo, type AgentTreeNode}
import eddie_shared/mailbox.{type MailMessage}
import eddie_shared/message
import eddie_shared/protocol.{
  type ClientCommand, type DirectorySnapshot, type FileSnapshot,
  type LogItemSnapshot, type ServerEvent, type TaskSnapshot, type TokenRecord,
}
import eddie_shared/task
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre_websocket as ws
import modem

// ============================================================================
// FFI
// ============================================================================

@external(javascript, "./eddie_frontend_ffi.mjs", "set_timeout")
fn ffi_set_timeout(callback: fn() -> Nil, delay_ms: Int) -> Nil

@external(javascript, "./eddie_frontend_ffi.mjs", "scroll_to_bottom")
fn ffi_scroll_to_bottom(element_id: String) -> Nil

// ============================================================================
// Model
// ============================================================================

type ConnectionStatus {
  Connecting
  Connected
  Disconnected
}

type Page {
  AgentListPage
  AgentConversationPage(agent_id: String)
}

type Panel {
  GoalPanel
  TasksPanel
  FilesPanel
  TokensPanel
  SubagentsPanel
  MailboxPanel
}

/// Per-agent cached state.
type AgentState {
  AgentState(
    goal: Option(String),
    system_prompt: String,
    tasks: List(TaskSnapshot),
    log: List(LogItemSnapshot),
    directories: List(DirectorySnapshot),
    files: List(FileSnapshot),
    token_records: List(TokenRecord),
    thinking: Bool,
    active_tool_calls: Dict(String, String),
    subagents: List(AgentInfo),
    inbox: List(MailMessage),
    outbox: List(MailMessage),
  )
}

fn empty_agent_state() -> AgentState {
  AgentState(
    goal: None,
    system_prompt: "",
    tasks: [],
    log: [],
    directories: [],
    files: [],
    token_records: [],
    thinking: False,
    active_tool_calls: dict.new(),
    subagents: [],
    inbox: [],
    outbox: [],
  )
}

type Model {
  Model(
    page: Page,
    /// Control WS — always connected, for tree events
    control_ws: Option(ws.WebSocket),
    control_connection: ConnectionStatus,
    control_ws_generation: Int,
    /// Agent WS — connected only when on conversation page
    agent_ws: Option(ws.WebSocket),
    agent_connection: ConnectionStatus,
    agent_ws_generation: Int,
    /// Agent tree (rose-tree forest)
    agent_tree: List(AgentTreeNode),
    /// Per-agent cached states
    agents: Dict(String, AgentState),
    chat_input: String,
    active_panel: Option(Panel),
  )
}

fn empty_model() -> Model {
  Model(
    page: AgentListPage,
    control_ws: None,
    control_connection: Connecting,
    control_ws_generation: 0,
    agent_ws: None,
    agent_connection: Disconnected,
    agent_ws_generation: 0,
    agent_tree: [],
    agents: dict.new(),
    chat_input: "",
    active_panel: None,
  )
}

/// Get the current agent's state (only valid on conversation page).
fn current_agent_state(model: Model) -> AgentState {
  case model.page {
    AgentConversationPage(agent_id) ->
      case dict.get(model.agents, agent_id) {
        Ok(state) -> state
        Error(_) -> empty_agent_state()
      }
    AgentListPage -> empty_agent_state()
  }
}

/// Update the current agent's state in the model.
fn set_current_agent_state(model: Model, state: AgentState) -> Model {
  case model.page {
    AgentConversationPage(agent_id) ->
      Model(..model, agents: dict.insert(model.agents, agent_id, state))
    AgentListPage -> model
  }
}

// ============================================================================
// Msg
// ============================================================================

type Msg {
  // Control WebSocket events
  ControlWsEvent(ws.WebSocketEvent)
  ControlReconnect(Int)
  ControlCheckConnection(Int)
  // Agent WebSocket events
  AgentWsEvent(ws.WebSocketEvent)
  AgentReconnect(Int)
  AgentCheckConnection(Int)
  // Navigation
  NavigateToAgent(String)
  NavigateToList
  UrlChanged(Page)
  // Agent list actions
  CreateRootAgent
  // Chat
  UpdateInput(String)
  SubmitMessage
  // Sidebar
  SetActivePanel(Option(Panel))
}

// ============================================================================
// Init
// ============================================================================

fn on_url_change(uri: uri.Uri) -> Msg {
  case uri.path_segments(uri.path) {
    ["agent", agent_id] -> UrlChanged(AgentConversationPage(agent_id))
    _ -> UrlChanged(AgentListPage)
  }
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let model = case modem.initial_uri() {
    Ok(uri) ->
      case uri.path_segments(uri.path) {
        ["agent", agent_id] ->
          Model(..empty_model(), page: AgentConversationPage(agent_id))
        _ -> empty_model()
      }
    Error(_) -> empty_model()
  }
  let initial_effects = [
    modem.init(on_url_change),
    ws.init("/ws/control", ControlWsEvent),
    delay_effect(ControlCheckConnection(model.control_ws_generation), 3000),
  ]
  let effects = case model.page {
    AgentConversationPage(agent_id) -> [
      ws.init("/ws/" <> agent_id, AgentWsEvent),
      delay_effect(AgentCheckConnection(model.agent_ws_generation), 3000),
      ..initial_effects
    ]
    AgentListPage -> initial_effects
  }
  #(model, effect.batch(effects))
}

fn navigate_to_page(
  model: Model,
  page: Page,
  push_url: Bool,
) -> #(Model, Effect(Msg)) {
  let close_effect = case model.agent_ws {
    Some(socket) ->
      effect.from(fn(_dispatch) {
        ws.close(socket)
        Nil
      })
    None -> effect.none()
  }
  case page {
    AgentConversationPage(agent_id) -> {
      let new_gen = model.agent_ws_generation + 1
      let new_model =
        Model(
          ..model,
          page: page,
          agent_ws: None,
          agent_connection: Connecting,
          agent_ws_generation: new_gen,
          agents: dict.insert(model.agents, agent_id, empty_agent_state()),
          active_panel: None,
        )
      let push_effect = case push_url {
        True -> modem.push("/agent/" <> agent_id, None, None)
        False -> effect.none()
      }
      #(
        new_model,
        effect.batch([
          close_effect,
          push_effect,
          ws.init("/ws/" <> agent_id, AgentWsEvent),
          delay_effect(AgentCheckConnection(new_gen), 3000),
        ]),
      )
    }
    AgentListPage -> {
      let push_effect = case push_url {
        True -> modem.push("/", None, None)
        False -> effect.none()
      }
      #(
        Model(
          ..model,
          page: AgentListPage,
          agent_ws: None,
          agent_connection: Disconnected,
        ),
        effect.batch([close_effect, push_effect]),
      )
    }
  }
}

// ============================================================================
// Update
// ============================================================================

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // -- Control WebSocket --------------------------------------------------
    ControlWsEvent(ws.OnOpen(socket)) -> #(
      Model(..model, control_ws: Some(socket), control_connection: Connected),
      effect.none(),
    )

    ControlWsEvent(ws.OnTextMessage(text)) -> {
      let events = parse_server_events(text)
      let new_model = apply_control_events(model, events)
      #(new_model, effect.none())
    }

    ControlWsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    ControlWsEvent(ws.OnClose(_)) ->
      case model.control_ws {
        Some(_) -> #(model, effect.none())
        None -> {
          let gen = model.control_ws_generation
          #(
            Model(..model, control_connection: Disconnected),
            delay_effect(ControlReconnect(gen), 2000),
          )
        }
      }

    ControlWsEvent(ws.InvalidUrl) -> {
      let gen = model.control_ws_generation
      #(
        Model(..model, control_connection: Connecting),
        delay_effect(ControlReconnect(gen), 2000),
      )
    }

    ControlReconnect(gen) ->
      case gen == model.control_ws_generation {
        False -> #(model, effect.none())
        True -> {
          let new_gen = model.control_ws_generation + 1
          #(
            Model(
              ..model,
              control_connection: Connecting,
              control_ws_generation: new_gen,
            ),
            effect.batch([
              ws.init("/ws/control", ControlWsEvent),
              delay_effect(ControlCheckConnection(new_gen), 3000),
            ]),
          )
        }
      }

    ControlCheckConnection(gen) ->
      case gen == model.control_ws_generation, model.control_connection {
        False, _ -> #(model, effect.none())
        _, Connected -> #(model, effect.none())
        True, _ -> #(
          model,
          effect.batch([
            ws.init("/ws/control", ControlWsEvent),
            delay_effect(ControlCheckConnection(gen), 3000),
          ]),
        )
      }

    // -- Agent WebSocket ----------------------------------------------------
    AgentWsEvent(ws.OnOpen(socket)) -> #(
      Model(..model, agent_ws: Some(socket), agent_connection: Connected),
      effect.none(),
    )

    AgentWsEvent(ws.OnTextMessage(text)) -> {
      let events = parse_server_events(text)
      let state = current_agent_state(model)
      let new_state = list.fold(events, state, apply_server_event)
      let new_model = set_current_agent_state(model, new_state)
      #(new_model, scroll_chat_effect())
    }

    AgentWsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    AgentWsEvent(ws.OnClose(_)) ->
      case model.agent_ws {
        Some(_) -> #(model, effect.none())
        None ->
          case model.agent_connection {
            Connecting -> #(model, effect.none())
            _ -> {
              let gen = model.agent_ws_generation
              #(
                Model(..model, agent_connection: Disconnected),
                delay_effect(AgentReconnect(gen), 2000),
              )
            }
          }
      }

    AgentWsEvent(ws.InvalidUrl) -> {
      let gen = model.agent_ws_generation
      #(
        Model(..model, agent_connection: Connecting),
        delay_effect(AgentReconnect(gen), 2000),
      )
    }

    AgentReconnect(gen) ->
      case gen == model.agent_ws_generation, model.page {
        False, _ -> #(model, effect.none())
        _, AgentListPage -> #(model, effect.none())
        True, AgentConversationPage(agent_id) -> {
          let new_gen = model.agent_ws_generation + 1
          #(
            Model(
              ..model,
              agent_connection: Connecting,
              agent_ws_generation: new_gen,
            ),
            effect.batch([
              ws.init("/ws/" <> agent_id, AgentWsEvent),
              delay_effect(AgentCheckConnection(new_gen), 3000),
            ]),
          )
        }
      }

    AgentCheckConnection(gen) ->
      case
        gen == model.agent_ws_generation,
        model.agent_connection,
        model.page
      {
        False, _, _ -> #(model, effect.none())
        _, Connected, _ -> #(model, effect.none())
        True, _, AgentConversationPage(agent_id) -> #(
          model,
          effect.batch([
            ws.init("/ws/" <> agent_id, AgentWsEvent),
            delay_effect(AgentCheckConnection(gen), 3000),
          ]),
        )
        _, _, _ -> #(model, effect.none())
      }

    // -- Navigation ---------------------------------------------------------
    NavigateToAgent(agent_id) ->
      navigate_to_page(model, AgentConversationPage(agent_id), True)

    NavigateToList -> navigate_to_page(model, AgentListPage, True)

    UrlChanged(page) ->
      case page == model.page {
        True -> #(model, effect.none())
        False -> navigate_to_page(model, page, False)
      }

    // -- Agent list actions -------------------------------------------------
    CreateRootAgent -> {
      case model.control_ws {
        None -> #(model, effect.none())
        Some(socket) -> {
          let command = protocol.SpawnRootAgent
          #(model, send_command(socket, command))
        }
      }
    }

    // -- Chat ---------------------------------------------------------------
    UpdateInput(text) -> #(Model(..model, chat_input: text), effect.none())

    SubmitMessage -> {
      let text = string.trim(model.chat_input)
      case text, model.agent_ws {
        "", _ -> #(model, effect.none())
        _, None -> #(model, effect.none())
        _, Some(socket) -> {
          let command = protocol.SendUserMessage(text:)
          #(Model(..model, chat_input: ""), send_command(socket, command))
        }
      }
    }

    // -- Sidebar ------------------------------------------------------------
    SetActivePanel(panel) -> {
      let new_panel = case model.active_panel == panel {
        True -> None
        False -> panel
      }
      #(Model(..model, active_panel: new_panel), effect.none())
    }
  }
}

fn parse_server_events(text: String) -> List(ServerEvent) {
  case json.parse(text, decode.list(protocol.server_event_decoder())) {
    Ok(events) -> events
    Error(_) ->
      case json.parse(text, protocol.server_event_decoder()) {
        Ok(event) -> [event]
        Error(_) -> []
      }
  }
}

/// Apply control-level events (tree changes).
fn apply_control_events(model: Model, events: List(ServerEvent)) -> Model {
  list.fold(events, model, fn(m, event) {
    case event {
      protocol.AgentTreeChanged(roots:) -> Model(..m, agent_tree: roots)
      _ -> m
    }
  })
}

/// Apply per-agent events to agent state.
fn apply_server_event(state: AgentState, event: ServerEvent) -> AgentState {
  case event {
    protocol.AgentStateSnapshot(
      goal:,
      system_prompt:,
      tasks:,
      log:,
      directories:,
      files:,
      token_records:,
      ..,
    ) ->
      AgentState(
        ..state,
        goal:,
        system_prompt:,
        tasks:,
        log:,
        directories:,
        files:,
        token_records:,
      )

    protocol.GoalUpdated(text:) -> AgentState(..state, goal: text)

    protocol.SystemPromptUpdated(text:) ->
      AgentState(..state, system_prompt: text)

    protocol.ConversationAppended(item:) ->
      AgentState(..state, log: list.append(state.log, [item]))

    protocol.TaskCreated(id:, description:) -> {
      let snapshot =
        protocol.TaskSnapshot(
          id:,
          description:,
          status: task.Pending,
          memories: [],
          ui_expanded: False,
        )
      // Upsert: reset if exists (handles full state re-sends), create if new
      case list.any(state.tasks, fn(t) { t.id == id }) {
        True ->
          AgentState(
            ..state,
            tasks: list.map(state.tasks, fn(t) {
              case t.id == id {
                True -> snapshot
                False -> t
              }
            }),
          )
        False ->
          AgentState(..state, tasks: list.append(state.tasks, [snapshot]))
      }
    }

    protocol.TaskStatusChanged(id:, status:) ->
      AgentState(
        ..state,
        tasks: list.map(state.tasks, fn(t) {
          case t.id == id {
            True -> protocol.TaskSnapshot(..t, status:)
            False -> t
          }
        }),
      )

    protocol.TaskMemoryAdded(id:, text:) ->
      AgentState(
        ..state,
        tasks: list.map(state.tasks, fn(t) {
          case t.id == id {
            True ->
              protocol.TaskSnapshot(
                ..t,
                memories: list.append(t.memories, [text]),
              )
            False -> t
          }
        }),
      )

    protocol.TaskMemoryRemoved(id:, index:) ->
      AgentState(
        ..state,
        tasks: list.map(state.tasks, fn(t) {
          case t.id == id {
            True ->
              protocol.TaskSnapshot(..t, memories: remove_at(t.memories, index))
            False -> t
          }
        }),
      )

    protocol.TaskMemoryEdited(id:, index:, new_text:) ->
      AgentState(
        ..state,
        tasks: list.map(state.tasks, fn(t) {
          case t.id == id {
            True ->
              protocol.TaskSnapshot(
                ..t,
                memories: replace_at(t.memories, index, new_text),
              )
            False -> t
          }
        }),
      )

    protocol.TokensUsed(input:, output:) -> {
      let record =
        protocol.TokenRecord(
          request_number: list.length(state.token_records) + 1,
          input_tokens: input,
          output_tokens: output,
        )
      AgentState(
        ..state,
        token_records: list.append(state.token_records, [record]),
      )
    }

    protocol.FileExplorerUpdated(directories:, files:) ->
      AgentState(..state, directories:, files:)

    protocol.ToolCallStarted(name:, call_id:, ..) ->
      AgentState(
        ..state,
        active_tool_calls: dict.insert(state.active_tool_calls, call_id, name),
      )

    protocol.ToolCallCompleted(call_id:, ..) ->
      AgentState(
        ..state,
        active_tool_calls: dict.delete(state.active_tool_calls, call_id),
      )

    protocol.TurnStarted -> AgentState(..state, thinking: True)

    protocol.TurnCompleted(..) ->
      AgentState(..state, thinking: False, active_tool_calls: dict.new())

    protocol.AgentError(..) ->
      AgentState(..state, thinking: False, active_tool_calls: dict.new())

    protocol.SubagentsUpdated(children:) ->
      AgentState(..state, subagents: children)

    protocol.MailboxUpdated(inbox:, outbox:) ->
      AgentState(..state, inbox: inbox, outbox: outbox)

    protocol.MailReceived(message:) ->
      AgentState(..state, inbox: list.append(state.inbox, [message]))

    protocol.MailSent(message:) ->
      AgentState(..state, outbox: list.append(state.outbox, [message]))

    // Tree-level events handled by apply_control_events
    protocol.AgentTreeChanged(..)
    | protocol.AgentSpawnFailed(..)
    | protocol.ChildAgentStatusChanged(..) -> state
  }
}

// ============================================================================
// Effects
// ============================================================================

fn send_command(socket: ws.WebSocket, command: ClientCommand) -> Effect(Msg) {
  let payload =
    command
    |> protocol.client_command_to_json
    |> json.to_string
  ws.send(socket, payload)
}

fn delay_effect(msg: Msg, delay_ms: Int) -> Effect(Msg) {
  effect.from(fn(dispatch) { ffi_set_timeout(fn() { dispatch(msg) }, delay_ms) })
}

fn scroll_chat_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { ffi_scroll_to_bottom("chat-log") })
}

// ============================================================================
// View — page dispatch
// ============================================================================

fn view(model: Model) -> Element(Msg) {
  case model.page {
    AgentListPage -> view_agent_list_page(model)
    AgentConversationPage(_) -> view_conversation_page(model)
  }
}

// ============================================================================
// Agent List Page
// ============================================================================

fn view_agent_list_page(model: Model) -> Element(Msg) {
  html.div([attribute.class("app")], [
    html.header([attribute.class("top-bar")], [
      html.h1([], [html.text("Eddie")]),
      view_control_status(model),
    ]),
    html.div([attribute.class("agent-list-page")], [
      html.div([attribute.class("agent-list-header")], [
        html.h2([], [html.text("Agents")]),
        html.button(
          [attribute.class("add-agent-btn"), event.on_click(CreateRootAgent)],
          [html.text("+ New Agent")],
        ),
      ]),
      case model.agent_tree {
        [] ->
          html.div([attribute.class("agent-list-empty")], [
            html.p([attribute.class("muted")], [
              html.text("No agents yet. Click \"+ New Agent\" to create one."),
            ]),
          ])
        roots ->
          html.div(
            [attribute.class("agent-list")],
            list.map(roots, view_agent_card),
          )
      },
    ]),
  ])
}

fn view_agent_card(node: AgentTreeNode) -> Element(Msg) {
  let info = node.info
  let status_text = agent_info.status_to_string(info.status)
  let child_count = list.length(node.children)
  let child_text = case child_count {
    0 -> ""
    1 -> "1 subagent"
    n -> int.to_string(n) <> " subagents"
  }
  html.div(
    [
      attribute.class("agent-card"),
      // stop_propagation prevents clicks on nested child cards from
      // also triggering the parent card's NavigateToAgent handler
      event.stop_propagation(event.on_click(NavigateToAgent(info.id))),
    ],
    [
      html.div([attribute.class("agent-card-header")], [
        html.span([attribute.class("agent-card-label")], [
          html.text(info.label),
        ]),
        html.span(
          [attribute.class("agent-card-status status-" <> status_text)],
          [html.text(status_text)],
        ),
      ]),
      html.div([attribute.class("agent-card-id")], [html.text(info.id)]),
      case child_text {
        "" -> html.text("")
        t -> html.div([attribute.class("agent-card-children")], [html.text(t)])
      },
      case node.children {
        [] -> html.text("")
        children ->
          html.div(
            [attribute.class("agent-card-subtree")],
            list.map(children, view_agent_card),
          )
      },
    ],
  )
}

fn view_control_status(model: Model) -> Element(Msg) {
  let status_class = case model.control_connection {
    Connected -> "status-connected"
    Connecting -> "status-connecting"
    Disconnected -> "status-disconnected"
  }
  let status_text = case model.control_connection {
    Connected -> "Connected"
    Connecting -> "Connecting..."
    Disconnected -> "Disconnected"
  }
  html.span([attribute.class("status " <> status_class)], [
    html.text(status_text),
  ])
}

// ============================================================================
// Conversation Page
// ============================================================================

fn view_conversation_page(model: Model) -> Element(Msg) {
  let state = current_agent_state(model)
  html.div([attribute.class("app")], [
    view_conversation_top_bar(model),
    html.div([attribute.class("main")], [
      view_sidebar(model, state),
      view_chat(model, state),
    ]),
  ])
}

fn view_conversation_top_bar(model: Model) -> Element(Msg) {
  let agent_id = case model.page {
    AgentConversationPage(id) -> id
    AgentListPage -> ""
  }
  let status_class = case model.agent_connection {
    Connected -> "status-connected"
    Connecting -> "status-connecting"
    Disconnected -> "status-disconnected"
  }
  let status_text = case model.agent_connection {
    Connected -> "Connected"
    Connecting -> "Connecting..."
    Disconnected -> "Disconnected"
  }
  html.header([attribute.class("top-bar")], [
    html.button([attribute.class("back-btn"), event.on_click(NavigateToList)], [
      html.text("< Back"),
    ]),
    html.h1([], [html.text(current_agent_label(model))]),
    html.span([attribute.class("agent-id-label")], [html.text(agent_id)]),
    html.span([attribute.class("status " <> status_class)], [
      html.text(status_text),
    ]),
  ])
}

fn view_sidebar(model: Model, state: AgentState) -> Element(Msg) {
  html.aside([attribute.class("sidebar")], [
    html.nav([attribute.class("sidebar-icons")], [
      sidebar_icon("Goal", GoalPanel, model.active_panel),
      sidebar_icon("Tasks", TasksPanel, model.active_panel),
      sidebar_icon("Files", FilesPanel, model.active_panel),
      sidebar_icon("Tokens", TokensPanel, model.active_panel),
      sidebar_icon("Agents", SubagentsPanel, model.active_panel),
      sidebar_icon("Mail", MailboxPanel, model.active_panel),
    ]),
    case model.active_panel {
      None -> html.text("")
      Some(panel) ->
        html.div([attribute.class("panel-content")], [
          case panel {
            GoalPanel -> view_goal_panel(state)
            TasksPanel -> view_tasks_panel(state)
            FilesPanel -> view_files_panel(state)
            TokensPanel -> view_tokens_panel(state)
            SubagentsPanel -> view_subagents_panel(state)
            MailboxPanel -> view_mailbox_panel(state)
          },
        ])
    },
  ])
}

fn sidebar_icon(
  label: String,
  panel: Panel,
  active: Option(Panel),
) -> Element(Msg) {
  let is_active = active == Some(panel)
  let classes = case is_active {
    True -> "sidebar-btn active"
    False -> "sidebar-btn"
  }
  html.button(
    [attribute.class(classes), event.on_click(SetActivePanel(Some(panel)))],
    [html.text(label)],
  )
}

fn view_goal_panel(state: AgentState) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Goal")]),
    case state.goal {
      None -> html.p([attribute.class("muted")], [html.text("No goal set")])
      Some(text) -> html.p([], [html.text(text)])
    },
  ])
}

fn view_tasks_panel(state: AgentState) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Tasks")]),
    case state.tasks {
      [] -> html.p([attribute.class("muted")], [html.text("No tasks")])
      tasks ->
        html.ul([attribute.class("task-list")], list.map(tasks, view_task_item))
    },
  ])
}

fn view_task_item(snapshot: TaskSnapshot) -> Element(Msg) {
  let icon = task.status_icon(snapshot.status)
  let status_class = task.status_to_string(snapshot.status)
  html.li([attribute.class("task-item " <> status_class)], [
    html.span([attribute.class("task-icon")], [html.text(icon)]),
    html.span([attribute.class("task-desc")], [
      html.text(snapshot.description),
    ]),
    case snapshot.memories {
      [] -> html.text("")
      memories ->
        html.ul(
          [attribute.class("task-memories")],
          list.map(memories, fn(m) { html.li([], [html.text(m)]) }),
        )
    },
  ])
}

fn view_files_panel(state: AgentState) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Files")]),
    case state.directories {
      [] ->
        html.p([attribute.class("muted")], [html.text("No directories open")])
      dirs ->
        html.div(
          [],
          list.map(dirs, fn(dir) {
            html.div([attribute.class("dir-entry")], [
              html.div([attribute.class("dir-path")], [html.text(dir.path)]),
              html.ul(
                [],
                list.map(dir.entries, fn(entry) {
                  let #(name, is_dir) = entry
                  let prefix = case is_dir {
                    True -> "/"
                    False -> ""
                  }
                  html.li([], [html.text(prefix <> name)])
                }),
              ),
            ])
          }),
        )
    },
  ])
}

fn view_tokens_panel(state: AgentState) -> Element(Msg) {
  let total_in =
    list.fold(state.token_records, 0, fn(acc, r) { acc + r.input_tokens })
  let total_out =
    list.fold(state.token_records, 0, fn(acc, r) { acc + r.output_tokens })
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Token Usage")]),
    html.div([attribute.class("token-summary")], [
      html.div([], [
        html.text(
          "Total: "
          <> int.to_string(total_in)
          <> " in / "
          <> int.to_string(total_out)
          <> " out",
        ),
      ]),
      html.div([], [
        html.text(
          "Requests: " <> int.to_string(list.length(state.token_records)),
        ),
      ]),
    ]),
  ])
}

fn view_subagents_panel(state: AgentState) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Subagents")]),
    case state.subagents {
      [] -> html.p([attribute.class("muted")], [html.text("No subagents")])
      agents ->
        html.ul(
          [attribute.class("task-list")],
          list.map(agents, fn(a) {
            html.li([attribute.class("task-item")], [
              html.span([attribute.class("task-icon")], [
                html.text(status_icon_for_agent(a.status)),
              ]),
              html.span([attribute.class("task-desc")], [
                html.text(a.label <> " (" <> a.id <> ")"),
              ]),
            ])
          }),
        )
    },
  ])
}

fn status_icon_for_agent(status: agent_info.AgentStatus) -> String {
  case status {
    agent_info.AgentIdle -> "[-]"
    agent_info.AgentRunning -> "[~]"
    agent_info.AgentCompleted -> "[x]"
    agent_info.AgentError -> "[!]"
  }
}

fn view_mailbox_panel(state: AgentState) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Mailbox")]),
    html.div([], [
      html.h3([], [
        html.text("Inbox (" <> int.to_string(list.length(state.inbox)) <> ")"),
      ]),
      case state.inbox {
        [] -> html.p([attribute.class("muted")], [html.text("No messages")])
        messages ->
          html.ul(
            [attribute.class("task-list")],
            list.map(messages, fn(m) {
              let read_class = case m.read {
                True -> "muted"
                False -> ""
              }
              html.li([attribute.class("task-item " <> read_class)], [
                html.span([], [
                  html.text(
                    "From " <> m.from <> ": " <> truncate(m.content, 80),
                  ),
                ]),
              ])
            }),
          )
      },
    ]),
    html.div([], [
      html.h3([], [
        html.text("Sent (" <> int.to_string(list.length(state.outbox)) <> ")"),
      ]),
      case state.outbox {
        [] -> html.p([attribute.class("muted")], [html.text("No messages")])
        messages ->
          html.ul(
            [attribute.class("task-list")],
            list.map(messages, fn(m) {
              html.li([attribute.class("task-item muted")], [
                html.span([], [
                  html.text("To " <> m.to <> ": " <> truncate(m.content, 80)),
                ]),
              ])
            }),
          )
      },
    ]),
  ])
}

// ============================================================================
// Chat view
// ============================================================================

fn view_chat(model: Model, state: AgentState) -> Element(Msg) {
  let label = current_agent_label(model)
  html.div([attribute.class("chat")], [
    html.div([attribute.class("chat-log"), attribute.id("chat-log")], [
      html.div([], list.map(state.log, view_log_item(_, label))),
      view_active_tool_calls(state),
      view_thinking_indicator(state),
    ]),
    view_input_bar(model),
  ])
}

fn view_log_item(item: LogItemSnapshot, agent_label: String) -> Element(Msg) {
  case item {
    protocol.UserMessageSnapshot(text:, ..) ->
      html.div([attribute.class("msg msg-user")], [
        html.div([attribute.class("msg-role")], [html.text("You")]),
        html.div([attribute.class("msg-content")], [html.text(text)]),
      ])

    protocol.SystemMessageSnapshot(text:, from:, ..) ->
      html.div([attribute.class("msg msg-system")], [
        html.div([attribute.class("msg-role")], [html.text(from)]),
        html.div([attribute.class("msg-content")], [html.text(text)]),
      ])

    protocol.ResponseSnapshot(response:, ..) -> {
      let text_parts =
        response.parts
        |> list.filter_map(fn(part) {
          case part {
            message.TextPart(content:) -> Ok(content)
            _ -> Error(Nil)
          }
        })
      let tool_calls =
        response.parts
        |> list.filter_map(fn(part) {
          case part {
            message.ToolCallPart(tool_name:, ..) -> Ok(tool_name)
            _ -> Error(Nil)
          }
        })
      html.div([attribute.class("msg msg-assistant")], [
        html.div([attribute.class("msg-role")], [html.text(agent_label)]),
        html.div(
          [attribute.class("msg-content")],
          list.append(
            list.map(text_parts, fn(t) { html.p([], [html.text(t)]) }),
            case tool_calls {
              [] -> []
              calls -> [
                html.div(
                  [attribute.class("tool-calls")],
                  list.map(calls, fn(name) {
                    html.span([attribute.class("tool-badge")], [
                      html.text(name),
                    ])
                  }),
                ),
              ]
            },
          ),
        ),
      ])
    }

    protocol.ToolResultsSnapshot(request:, ..) -> {
      let results =
        request.parts
        |> list.filter_map(fn(part) {
          case part {
            message.ToolReturnPart(tool_name:, content:, ..) ->
              Ok(#(tool_name, content))
            _ -> Error(Nil)
          }
        })
      case results {
        [] -> html.text("")
        _ ->
          html.div(
            [attribute.class("msg msg-tool-results")],
            list.map(results, fn(r) {
              let #(name, content) = r
              html.details([attribute.class("tool-result")], [
                html.summary([], [html.text(name)]),
                html.pre([], [html.text(truncate(content, 500))]),
              ])
            }),
          )
      }
    }
  }
}

fn view_active_tool_calls(state: AgentState) -> Element(Msg) {
  let calls = dict.to_list(state.active_tool_calls)
  case calls {
    [] -> html.text("")
    _ ->
      html.div(
        [attribute.class("active-tools")],
        list.map(calls, fn(entry) {
          let #(_id, name) = entry
          html.span([attribute.class("tool-badge running")], [
            html.text(name <> "..."),
          ])
        }),
      )
  }
}

fn view_thinking_indicator(state: AgentState) -> Element(Msg) {
  case state.thinking {
    False -> html.text("")
    True ->
      html.div([attribute.class("thinking")], [
        html.span([attribute.class("thinking-dot")], []),
        html.text(" Thinking..."),
      ])
  }
}

fn view_input_bar(model: Model) -> Element(Msg) {
  let is_subagent = is_current_agent_subagent(model)
  let disabled = model.agent_connection != Connected || is_subagent
  let placeholder = case is_subagent {
    True -> "This is a subagent, only its parent can send messages to it."
    False -> "Send a message..."
  }
  html.div([attribute.class("input-bar")], [
    html.input([
      attribute.class("chat-input"),
      attribute.value(model.chat_input),
      attribute.placeholder(placeholder),
      attribute.disabled(disabled),
      event.on_input(UpdateInput),
      on_enter_key(SubmitMessage),
    ]),
    html.button(
      [
        attribute.class("send-btn"),
        attribute.disabled(disabled),
        event.on_click(SubmitMessage),
      ],
      [html.text("Send")],
    ),
  ])
}

fn on_enter_key(msg: Msg) -> Attribute(Msg) {
  event.on("keydown", {
    use key <- decode.field("key", decode.string)
    case key {
      "Enter" -> decode.success(msg)
      _ -> decode.failure(msg, "Enter key")
    }
  })
}

// ============================================================================
// Helpers
// ============================================================================

/// Check if the currently viewed agent is a subagent (has a parent).
fn current_agent_label(model: Model) -> String {
  case model.page {
    AgentListPage -> "Eddie"
    AgentConversationPage(agent_id) ->
      find_agent_info(model.agent_tree, agent_id)
      |> option.map(fn(info) { info.label })
      |> option.unwrap("Eddie")
  }
}

fn is_current_agent_subagent(model: Model) -> Bool {
  case model.page {
    AgentListPage -> False
    AgentConversationPage(agent_id) ->
      find_agent_info(model.agent_tree, agent_id)
      |> option.map(fn(info) { option.is_some(info.parent_id) })
      |> option.unwrap(False)
  }
}

/// Search the agent tree forest for an AgentInfo by ID.
fn find_agent_info(
  nodes: List(AgentTreeNode),
  target_id: String,
) -> Option(AgentInfo) {
  case nodes {
    [] -> None
    [node, ..rest] ->
      case node.info.id == target_id {
        True -> Some(node.info)
        False ->
          case find_agent_info(node.children, target_id) {
            Some(info) -> Some(info)
            None -> find_agent_info(rest, target_id)
          }
      }
  }
}

fn remove_at(items: List(a), index: Int) -> List(a) {
  items
  |> list.index_map(fn(item, i) { #(i, item) })
  |> list.filter(fn(pair) { pair.0 != index })
  |> list.map(fn(pair) { pair.1 })
}

fn replace_at(items: List(String), index: Int, value: String) -> List(String) {
  list.index_map(items, fn(item, i) {
    case i == index {
      True -> value
      False -> item
    }
  })
}

fn truncate(text: String, max_len: Int) -> String {
  case string.length(text) > max_len {
    True -> string.slice(text, 0, max_len) <> "..."
    False -> text
  }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
