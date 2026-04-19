/// Eddie frontend — Lustre SPA.
///
/// Single-module Lustre application that connects to the backend via
/// WebSocket and renders a chat UI with sidebar panels.
/// Supports multiple agents — each agent has its own WebSocket connection
/// and cached state. The user switches between agents via a tab bar.
import eddie_shared/message
import eddie_shared/protocol.{
  type AgentInfo, type ClientCommand, type DirectorySnapshot, type FileSnapshot,
  type LogItemSnapshot, type ServerEvent, type TaskSnapshot, type TokenRecord,
  AgentInfo,
}
import eddie_shared/task
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre_websocket as ws

// ============================================================================
// FFI
// ============================================================================

@external(javascript, "./eddie_frontend_ffi.mjs", "set_timeout")
fn ffi_set_timeout(callback: fn() -> Nil, delay_ms: Int) -> Nil

@external(javascript, "./eddie_frontend_ffi.mjs", "scroll_to_bottom")
fn ffi_scroll_to_bottom(element_id: String) -> Nil

@external(javascript, "./eddie_frontend_ffi.mjs", "fetch_json")
fn ffi_fetch_json(url: String, callback: fn(String) -> Nil) -> Nil

// ============================================================================
// Model
// ============================================================================

type ConnectionStatus {
  Connecting
  Connected
  Disconnected
}

type Panel {
  GoalPanel
  TasksPanel
  FilesPanel
  TokensPanel
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
  )
}

/// State for the inline spawn-agent form.
type SpawnForm {
  SpawnForm(id: String, label: String, system_prompt: String)
}

fn empty_spawn_form() -> SpawnForm {
  SpawnForm(id: "", label: "", system_prompt: "")
}

type Model {
  Model(
    ws: Option(ws.WebSocket),
    connection: ConnectionStatus,
    active_agent: String,
    agent_list: List(AgentInfo),
    agents: Dict(String, AgentState),
    chat_input: String,
    active_panel: Option(Panel),
    show_spawn_form: Bool,
    spawn_form: SpawnForm,
  )
}

fn empty_model() -> Model {
  Model(
    ws: None,
    connection: Connecting,
    active_agent: "root",
    agent_list: [AgentInfo(id: "root", label: "Root")],
    agents: dict.from_list([#("root", empty_agent_state())]),
    chat_input: "",
    active_panel: None,
    show_spawn_form: False,
    spawn_form: empty_spawn_form(),
  )
}

/// Get the active agent's state (never fails — empty state as fallback).
fn active_state(model: Model) -> AgentState {
  case dict.get(model.agents, model.active_agent) {
    Ok(state) -> state
    Error(_) -> empty_agent_state()
  }
}

/// Update the active agent's state in the model.
fn set_active_state(model: Model, state: AgentState) -> Model {
  Model(..model, agents: dict.insert(model.agents, model.active_agent, state))
}

// ============================================================================
// Msg
// ============================================================================

type Msg {
  WsEvent(ws.WebSocketEvent)
  UpdateInput(String)
  SubmitMessage
  SetActivePanel(Option(Panel))
  AttemptReconnect
  CheckConnection
  SwitchAgent(String)
  AgentListReceived(String)
  ToggleSpawnForm
  UpdateSpawnId(String)
  UpdateSpawnLabel(String)
  UpdateSpawnPrompt(String)
  SubmitSpawn
}

// ============================================================================
// Init
// ============================================================================

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(
    empty_model(),
    effect.batch([
      ws.init("/ws/root", WsEvent),
      fetch_agent_list(),
      delay_effect(CheckConnection, 3000),
    ]),
  )
}

// ============================================================================
// Update
// ============================================================================

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WsEvent(ws.OnOpen(socket)) -> #(
      Model(..model, ws: Some(socket), connection: Connected),
      effect.none(),
    )

    WsEvent(ws.OnTextMessage(text)) -> {
      let events = parse_server_events(text)
      let agent_state = active_state(model)
      let new_agent_state = list.fold(events, agent_state, apply_server_event)
      let new_model =
        set_active_state(model, new_agent_state)
        |> apply_model_events(events)
      let scroll = scroll_chat_effect()
      #(new_model, scroll)
    }

    WsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    WsEvent(ws.OnClose(_)) -> #(
      Model(..model, ws: None, connection: Disconnected),
      delay_effect(AttemptReconnect, 2000),
    )

    WsEvent(ws.InvalidUrl) -> #(
      Model(..model, connection: Connecting),
      delay_effect(AttemptReconnect, 2000),
    )

    AttemptReconnect -> #(
      Model(..model, connection: Connecting),
      effect.batch([
        ws.init("/ws/" <> model.active_agent, WsEvent),
        delay_effect(CheckConnection, 3000),
      ]),
    )

    // Connection watchdog: if still Connecting after the timer, retry
    CheckConnection -> case model.connection {
      Connecting -> #(
        model,
        effect.batch([
          ws.init("/ws/" <> model.active_agent, WsEvent),
          delay_effect(CheckConnection, 3000),
        ]),
      )
      _ -> #(model, effect.none())
    }

    UpdateInput(text) -> #(Model(..model, chat_input: text), effect.none())

    SubmitMessage -> {
      let text = string.trim(model.chat_input)
      case text, model.ws {
        "", _ -> #(model, effect.none())
        _, None -> #(model, effect.none())
        _, Some(socket) -> {
          let command = protocol.SendUserMessage(text:)
          #(Model(..model, chat_input: ""), send_command(socket, command))
        }
      }
    }

    SetActivePanel(panel) -> {
      let new_panel = case model.active_panel == panel {
        True -> None
        False -> panel
      }
      #(Model(..model, active_panel: new_panel), effect.none())
    }

    SwitchAgent(agent_id) -> {
      case agent_id == model.active_agent {
        True -> #(model, effect.none())
        False -> {
          // Close current WebSocket, open new one for the selected agent
          let close_effect = case model.ws {
            Some(socket) -> ws.close(socket)
            None -> effect.none()
          }
          let new_model =
            Model(
              ..model,
              active_agent: agent_id,
              ws: None,
              connection: Connecting,
            )
          #(
            new_model,
            effect.batch([
              close_effect,
              ws.init("/ws/" <> agent_id, WsEvent),
              delay_effect(CheckConnection, 3000),
            ]),
          )
        }
      }
    }

    AgentListReceived(text) -> {
      case json.parse(text, decode.list(protocol.agent_info_decoder())) {
        Ok(agents) -> #(Model(..model, agent_list: agents), effect.none())
        Error(_) -> #(model, effect.none())
      }
    }

    ToggleSpawnForm -> #(
      Model(
        ..model,
        show_spawn_form: !model.show_spawn_form,
        spawn_form: empty_spawn_form(),
      ),
      effect.none(),
    )

    UpdateSpawnId(value) -> #(
      Model(..model, spawn_form: SpawnForm(..model.spawn_form, id: value)),
      effect.none(),
    )

    UpdateSpawnLabel(value) -> #(
      Model(..model, spawn_form: SpawnForm(..model.spawn_form, label: value)),
      effect.none(),
    )

    UpdateSpawnPrompt(value) -> #(
      Model(
        ..model,
        spawn_form: SpawnForm(..model.spawn_form, system_prompt: value),
      ),
      effect.none(),
    )

    SubmitSpawn -> {
      let form = model.spawn_form
      let id = string.trim(form.id)
      let label = string.trim(form.label)
      case id, label, model.ws {
        "", _, _ -> #(model, effect.none())
        _, "", _ -> #(model, effect.none())
        _, _, None -> #(model, effect.none())
        _, _, Some(socket) -> {
          let prompt = case string.trim(form.system_prompt) {
            "" -> "You are " <> label <> ", a helpful AI assistant."
            p -> p
          }
          let command = protocol.SpawnAgent(id:, label:, system_prompt: prompt)
          #(
            Model(
              ..model,
              show_spawn_form: False,
              spawn_form: empty_spawn_form(),
            ),
            send_command(socket, command),
          )
        }
      }
    }
  }
}

fn parse_server_events(text: String) -> List(ServerEvent) {
  // Backend sends JSON arrays of events
  case json.parse(text, decode.list(protocol.server_event_decoder())) {
    Ok(events) -> events
    Error(_) ->
      // Try single event
      case json.parse(text, protocol.server_event_decoder()) {
        Ok(event) -> [event]
        Error(_) -> []
      }
  }
}

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
      AgentState(..state, tasks: list.append(state.tasks, [snapshot]))
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

    // AgentListChanged and AgentSpawnFailed are handled at the Model level,
    // not the per-agent state level — they pass through here unchanged.
    protocol.AgentListChanged(..) | protocol.AgentSpawnFailed(..) -> state
  }
}

/// Apply model-level events (agent list changes) after per-agent state updates.
fn apply_model_events(model: Model, events: List(ServerEvent)) -> Model {
  list.fold(events, model, fn(m, event) {
    case event {
      protocol.AgentListChanged(agents:) -> Model(..m, agent_list: agents)
      _ -> m
    }
  })
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

fn fetch_agent_list() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi_fetch_json("/agents", fn(text) { dispatch(AgentListReceived(text)) })
  })
}

// ============================================================================
// View
// ============================================================================

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("app")], [
    view_top_bar(model),
    html.div([attribute.class("main")], [
      view_sidebar(model),
      view_chat(model),
    ]),
  ])
}

fn view_top_bar(model: Model) -> Element(Msg) {
  let status_class = case model.connection {
    Connected -> "status-connected"
    Connecting -> "status-connecting"
    Disconnected -> "status-disconnected"
  }
  let status_text = case model.connection {
    Connected -> "Connected"
    Connecting -> "Connecting..."
    Disconnected -> "Disconnected"
  }
  html.header([attribute.class("top-bar")], [
    html.h1([], [html.text("Eddie")]),
    html.span([attribute.class("status " <> status_class)], [
      html.text(status_text),
    ]),
    view_agent_tabs(model),
  ])
}

fn view_agent_tabs(model: Model) -> Element(Msg) {
  let tabs =
    list.map(model.agent_list, fn(info) {
      let is_active = info.id == model.active_agent
      let classes = case is_active {
        True -> "agent-tab active"
        False -> "agent-tab"
      }
      html.button(
        [attribute.class(classes), event.on_click(SwitchAgent(info.id))],
        [html.text(info.label)],
      )
    })
  let add_or_form = case model.show_spawn_form {
    False ->
      html.button(
        [attribute.class("add-agent-btn"), event.on_click(ToggleSpawnForm)],
        [html.text("+")],
      )
    True -> view_spawn_form(model.spawn_form)
  }
  html.div([attribute.class("agent-tabs")], list.append(tabs, [add_or_form]))
}

fn view_spawn_form(form: SpawnForm) -> Element(Msg) {
  html.div([attribute.class("spawn-form")], [
    html.input([
      attribute.class("spawn-input"),
      attribute.placeholder("id"),
      attribute.value(form.id),
      event.on_input(UpdateSpawnId),
    ]),
    html.input([
      attribute.class("spawn-input"),
      attribute.placeholder("label"),
      attribute.value(form.label),
      event.on_input(UpdateSpawnLabel),
    ]),
    html.input([
      attribute.class("spawn-input wide"),
      attribute.placeholder("system prompt (optional)"),
      attribute.value(form.system_prompt),
      event.on_input(UpdateSpawnPrompt),
      on_enter_key(SubmitSpawn),
    ]),
    html.button([attribute.class("spawn-submit"), event.on_click(SubmitSpawn)], [
      html.text("Create"),
    ]),
    html.button(
      [attribute.class("spawn-cancel"), event.on_click(ToggleSpawnForm)],
      [html.text("Cancel")],
    ),
  ])
}

fn view_sidebar(model: Model) -> Element(Msg) {
  let state = active_state(model)
  html.aside([attribute.class("sidebar")], [
    html.nav([attribute.class("sidebar-icons")], [
      sidebar_icon("Goal", GoalPanel, model.active_panel),
      sidebar_icon("Tasks", TasksPanel, model.active_panel),
      sidebar_icon("Files", FilesPanel, model.active_panel),
      sidebar_icon("Tokens", TokensPanel, model.active_panel),
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

// ============================================================================
// Chat view
// ============================================================================

fn view_chat(model: Model) -> Element(Msg) {
  let state = active_state(model)
  html.div([attribute.class("chat")], [
    html.div([attribute.class("chat-log"), attribute.id("chat-log")], [
      html.div([], list.map(state.log, view_log_item)),
      view_active_tool_calls(state),
      view_thinking_indicator(state),
    ]),
    view_input_bar(model),
  ])
}

fn view_log_item(item: LogItemSnapshot) -> Element(Msg) {
  case item {
    protocol.UserMessageSnapshot(text:, ..) ->
      html.div([attribute.class("msg msg-user")], [
        html.div([attribute.class("msg-role")], [html.text("You")]),
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
        html.div([attribute.class("msg-role")], [html.text("Eddie")]),
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
  let disabled = model.connection != Connected
  html.div([attribute.class("input-bar")], [
    html.input([
      attribute.class("chat-input"),
      attribute.value(model.chat_input),
      attribute.placeholder("Send a message..."),
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
