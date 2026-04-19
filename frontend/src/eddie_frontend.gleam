/// Eddie frontend — Lustre SPA.
///
/// Single-module Lustre application that connects to the backend via
/// WebSocket and renders a chat UI with sidebar panels.
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

type Model {
  Model(
    ws: Option(ws.WebSocket),
    connection: ConnectionStatus,
    goal: Option(String),
    system_prompt: String,
    tasks: List(TaskSnapshot),
    log: List(LogItemSnapshot),
    directories: List(DirectorySnapshot),
    files: List(FileSnapshot),
    token_records: List(TokenRecord),
    chat_input: String,
    thinking: Bool,
    active_tool_calls: Dict(String, String),
    active_panel: Option(Panel),
  )
}

fn empty_model() -> Model {
  Model(
    ws: None,
    connection: Connecting,
    goal: None,
    system_prompt: "",
    tasks: [],
    log: [],
    directories: [],
    files: [],
    token_records: [],
    chat_input: "",
    thinking: False,
    active_tool_calls: dict.new(),
    active_panel: None,
  )
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
}

// ============================================================================
// Init
// ============================================================================

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(empty_model(), ws.init("/ws", WsEvent))
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
      let new_model = list.fold(events, model, apply_server_event)
      let scroll = scroll_chat_effect()
      #(new_model, scroll)
    }

    WsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    WsEvent(ws.OnClose(_)) -> #(
      Model(..model, ws: None, connection: Disconnected, thinking: False),
      delay_effect(AttemptReconnect, 2000),
    )

    WsEvent(ws.InvalidUrl) -> #(
      Model(..model, connection: Disconnected),
      effect.none(),
    )

    AttemptReconnect -> #(
      Model(..model, connection: Connecting),
      ws.init("/ws", WsEvent),
    )

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

fn apply_server_event(model: Model, event: ServerEvent) -> Model {
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
      Model(
        ..model,
        goal:,
        system_prompt:,
        tasks:,
        log:,
        directories:,
        files:,
        token_records:,
      )

    protocol.GoalUpdated(text:) -> Model(..model, goal: text)

    protocol.SystemPromptUpdated(text:) -> Model(..model, system_prompt: text)

    protocol.ConversationAppended(item:) ->
      Model(..model, log: list.append(model.log, [item]))

    protocol.TaskCreated(id:, description:) -> {
      let snapshot =
        protocol.TaskSnapshot(
          id:,
          description:,
          status: task.Pending,
          memories: [],
          ui_expanded: False,
        )
      Model(..model, tasks: list.append(model.tasks, [snapshot]))
    }

    protocol.TaskStatusChanged(id:, status:) ->
      Model(
        ..model,
        tasks: list.map(model.tasks, fn(t) {
          case t.id == id {
            True -> protocol.TaskSnapshot(..t, status:)
            False -> t
          }
        }),
      )

    protocol.TaskMemoryAdded(id:, text:) ->
      Model(
        ..model,
        tasks: list.map(model.tasks, fn(t) {
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
      Model(
        ..model,
        tasks: list.map(model.tasks, fn(t) {
          case t.id == id {
            True ->
              protocol.TaskSnapshot(..t, memories: remove_at(t.memories, index))
            False -> t
          }
        }),
      )

    protocol.TaskMemoryEdited(id:, index:, new_text:) ->
      Model(
        ..model,
        tasks: list.map(model.tasks, fn(t) {
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
          request_number: list.length(model.token_records) + 1,
          input_tokens: input,
          output_tokens: output,
        )
      Model(..model, token_records: list.append(model.token_records, [record]))
    }

    protocol.FileExplorerUpdated(directories:, files:) ->
      Model(..model, directories:, files:)

    protocol.ToolCallStarted(name:, call_id:, ..) ->
      Model(
        ..model,
        active_tool_calls: dict.insert(model.active_tool_calls, call_id, name),
      )

    protocol.ToolCallCompleted(call_id:, ..) ->
      Model(
        ..model,
        active_tool_calls: dict.delete(model.active_tool_calls, call_id),
      )

    protocol.TurnStarted -> Model(..model, thinking: True)

    protocol.TurnCompleted(..) ->
      Model(..model, thinking: False, active_tool_calls: dict.new())

    protocol.AgentError(..) ->
      Model(..model, thinking: False, active_tool_calls: dict.new())
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
  ])
}

fn view_sidebar(model: Model) -> Element(Msg) {
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
            GoalPanel -> view_goal_panel(model)
            TasksPanel -> view_tasks_panel(model)
            FilesPanel -> view_files_panel(model)
            TokensPanel -> view_tokens_panel(model)
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

fn view_goal_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Goal")]),
    case model.goal {
      None -> html.p([attribute.class("muted")], [html.text("No goal set")])
      Some(text) -> html.p([], [html.text(text)])
    },
  ])
}

fn view_tasks_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Tasks")]),
    case model.tasks {
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

fn view_files_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("panel")], [
    html.h3([], [html.text("Files")]),
    case model.directories {
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

fn view_tokens_panel(model: Model) -> Element(Msg) {
  let total_in =
    list.fold(model.token_records, 0, fn(acc, r) { acc + r.input_tokens })
  let total_out =
    list.fold(model.token_records, 0, fn(acc, r) { acc + r.output_tokens })
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
          "Requests: " <> int.to_string(list.length(model.token_records)),
        ),
      ]),
    ]),
  ])
}

// ============================================================================
// Chat view
// ============================================================================

fn view_chat(model: Model) -> Element(Msg) {
  html.div([attribute.class("chat")], [
    html.div([attribute.class("chat-log"), attribute.id("chat-log")], [
      html.div([], list.map(model.log, view_log_item)),
      view_active_tool_calls(model),
      view_thinking_indicator(model),
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

fn view_active_tool_calls(model: Model) -> Element(Msg) {
  let calls = dict.to_list(model.active_tool_calls)
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

fn view_thinking_indicator(model: Model) -> Element(Msg) {
  case model.thinking {
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
