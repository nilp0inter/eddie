/// HTTP server and WebSocket handler — serves the Eddie web UI.
///
/// Uses mist for HTTP serving and WebSocket connections.
/// Each WebSocket connection subscribes to a specific agent (identified
/// by path: /ws/<agent_id>) for state updates.
import eddie/agent.{type AgentMessage}
import eddie/agent_tree.{type AgentTreeMessage}
import eddie_shared/agent_info
import eddie_shared/protocol
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import mist
import simplifile

/// Configuration for the web server.
pub type ServerConfig {
  ServerConfig(port: Int)
}

// ============================================================================
// WebSocket registry — tracks all connected clients for broadcasts
// ============================================================================

/// Messages for the WebSocket registry actor.
pub opaque type RegistryMessage {
  Register(subject: Subject(String))
  Unregister(subject: Subject(String))
  Broadcast(payload: String)
}

type RegistryState {
  RegistryState(clients: List(Subject(String)))
}

fn start_registry() -> Result(Subject(RegistryMessage), actor.StartError) {
  let result =
    actor.new(RegistryState(clients: []))
    |> actor.on_message(handle_registry_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

fn handle_registry_message(
  state: RegistryState,
  msg: RegistryMessage,
) -> actor.Next(RegistryState, RegistryMessage) {
  case msg {
    Register(subject) ->
      actor.continue(RegistryState(clients: [subject, ..state.clients]))
    Unregister(subject) ->
      actor.continue(
        RegistryState(
          clients: list.filter(state.clients, fn(s) { s != subject }),
        ),
      )
    Broadcast(payload) -> {
      list.each(state.clients, fn(s) { process.send(s, payload) })
      actor.continue(state)
    }
  }
}

fn registry_register(
  registry: Subject(RegistryMessage),
  subject: Subject(String),
) -> Nil {
  process.send(registry, Register(subject:))
}

fn registry_unregister(
  registry: Subject(RegistryMessage),
  subject: Subject(String),
) -> Nil {
  process.send(registry, Unregister(subject:))
}

fn registry_broadcast(
  registry: Subject(RegistryMessage),
  payload: String,
) -> Nil {
  process.send(registry, Broadcast(payload:))
}

// ============================================================================
// Server start
// ============================================================================

/// Start the HTTP + WebSocket server.
pub fn start(
  config config: ServerConfig,
  tree tree: Subject(AgentTreeMessage),
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let assert Ok(registry) = start_registry()
  mist.new(fn(req) { handle_request(req, tree, registry) })
  |> mist.port(config.port)
  |> mist.bind("0.0.0.0")
  |> mist.start
}

// ============================================================================
// HTTP request routing
// ============================================================================

fn handle_request(
  req: request.Request(mist.Connection),
  tree: Subject(AgentTreeMessage),
  registry: Subject(RegistryMessage),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [] -> serve_index()
    ["app.js"] -> serve_app_js()
    ["agents"] -> serve_agents(tree)
    ["ws", agent_id] -> upgrade_websocket(req, tree, registry, agent_id)
    _ -> not_found()
  }
}

fn serve_index() -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index_html())))
}

fn serve_app_js() -> response.Response(mist.ResponseData) {
  case simplifile.read("../frontend/build/app.js") {
    Ok(js) ->
      response.new(200)
      |> response.set_header("content-type", "application/javascript")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(js)))
    Error(_) ->
      response.new(404)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("app.js not found")),
      )
  }
}

fn serve_agents(
  tree: Subject(AgentTreeMessage),
) -> response.Response(mist.ResponseData) {
  let roots = agent_tree.get_tree(tree: tree)
  let body =
    json.to_string(json.array(roots, agent_info.agent_tree_node_to_json))
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
}

fn index_html() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Eddie</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'SF Mono', 'Fira Code', monospace; background: #1e1e2e; color: #cdd6f4; height: 100vh; }
    .app { display: flex; flex-direction: column; height: 100vh; }
    .top-bar { display: flex; align-items: center; gap: 12px; padding: 8px 16px; background: #181825; border-bottom: 1px solid #313244; }
    .top-bar h1 { font-size: 16px; color: #cba6f7; }
    .status { font-size: 11px; padding: 2px 8px; border-radius: 8px; }
    .status-connected { color: #a6e3a1; background: #a6e3a11a; }
    .status-connecting { color: #f9e2af; background: #f9e2af1a; }
    .status-disconnected { color: #f38ba8; background: #f38ba81a; }
    .agent-tabs { display: flex; gap: 2px; margin-left: auto; }
    .agent-tab { font-size: 11px; padding: 4px 10px; border-radius: 4px; border: none; cursor: pointer; font-family: inherit; background: none; color: #6c7086; }
    .agent-tab:hover { color: #cdd6f4; background: #313244; }
    .agent-tab.active { color: #cba6f7; background: #31324480; }
    .add-agent-btn { font-size: 11px; padding: 4px 8px; border-radius: 4px; border: 1px dashed #45475a; cursor: pointer; font-family: inherit; background: none; color: #6c7086; }
    .add-agent-btn:hover { color: #cdd6f4; border-color: #6c7086; }
    .spawn-form { display: flex; gap: 6px; align-items: center; }
    .spawn-input { padding: 3px 8px; background: #313244; color: #cdd6f4; border: 1px solid #45475a; border-radius: 4px; font-family: inherit; font-size: 11px; outline: none; width: 100px; }
    .spawn-input:focus { border-color: #cba6f7; }
    .spawn-input.wide { width: 180px; }
    .spawn-submit { font-size: 11px; padding: 3px 8px; background: #a6e3a1; color: #1e1e2e; border: none; border-radius: 4px; cursor: pointer; font-family: inherit; font-weight: 600; }
    .spawn-submit:hover { background: #94e2d5; }
    .spawn-cancel { font-size: 11px; padding: 3px 8px; background: none; color: #6c7086; border: 1px solid #45475a; border-radius: 4px; cursor: pointer; font-family: inherit; }
    .spawn-cancel:hover { color: #f38ba8; border-color: #f38ba8; }
    .main { display: flex; flex: 1; overflow: hidden; }
    .sidebar { display: flex; background: #181825; border-right: 1px solid #313244; }
    .sidebar-icons { display: flex; flex-direction: column; gap: 2px; padding: 4px; }
    .sidebar-btn { background: none; border: none; color: #6c7086; padding: 8px; cursor: pointer; border-radius: 4px; font-size: 11px; font-family: inherit; }
    .sidebar-btn:hover { color: #cdd6f4; background: #313244; }
    .sidebar-btn.active { color: #cba6f7; background: #31324480; }
    .panel-content { width: 240px; padding: 12px; overflow-y: auto; border-left: 1px solid #313244; }
    .panel h3 { font-size: 12px; color: #a6adc8; text-transform: uppercase; margin-bottom: 8px; letter-spacing: 0.5px; }
    .muted { color: #6c7086; font-size: 12px; }
    .task-list { list-style: none; }
    .task-item { padding: 4px 0; font-size: 12px; display: flex; gap: 6px; align-items: flex-start; }
    .task-icon { color: #f9e2af; flex-shrink: 0; }
    .task-item.done .task-desc { color: #6c7086; text-decoration: line-through; }
    .task-memories { list-style: disc; margin: 2px 0 2px 20px; font-size: 11px; color: #6c7086; }
    .dir-entry { margin-bottom: 8px; }
    .dir-path { font-size: 11px; color: #89b4fa; margin-bottom: 2px; }
    .dir-entry ul { list-style: none; font-size: 11px; padding-left: 12px; }
    .token-summary { font-size: 12px; }
    .token-summary > div { margin-bottom: 4px; }
    .chat { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    .chat-log { flex: 1; overflow-y: auto; padding: 16px; }
    .msg { margin-bottom: 16px; }
    .msg-role { font-size: 11px; font-weight: 600; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
    .msg-user .msg-role { color: #89b4fa; }
    .msg-assistant .msg-role { color: #cba6f7; }
    .msg-content { font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
    .msg-content p { margin-bottom: 8px; }
    .msg-content p:last-child { margin-bottom: 0; }
    .tool-calls { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
    .tool-badge { font-size: 10px; padding: 2px 6px; border-radius: 4px; background: #31324480; color: #a6adc8; }
    .tool-badge.running { background: #cba6f71a; color: #cba6f7; }
    .msg-tool-results { margin-bottom: 12px; }
    .tool-result { font-size: 12px; margin-bottom: 4px; }
    .tool-result summary { cursor: pointer; color: #a6adc8; }
    .tool-result pre { margin-top: 4px; padding: 8px; background: #11111b; border-radius: 4px; font-size: 11px; overflow-x: auto; max-height: 200px; overflow-y: auto; }
    .active-tools { display: flex; flex-wrap: wrap; gap: 4px; padding: 0 16px 8px; }
    .thinking { padding: 0 16px 8px; font-size: 12px; color: #6c7086; display: flex; align-items: center; gap: 6px; }
    .thinking-dot { width: 6px; height: 6px; border-radius: 50%; background: #cba6f7; animation: pulse 1.2s ease-in-out infinite; }
    @keyframes pulse { 0%, 100% { opacity: 0.3; } 50% { opacity: 1; } }
    .input-bar { display: flex; gap: 8px; padding: 12px 16px; background: #181825; border-top: 1px solid #313244; }
    .chat-input { flex: 1; padding: 8px 12px; background: #313244; color: #cdd6f4; border: 1px solid #45475a; border-radius: 6px; font-family: inherit; font-size: 13px; outline: none; }
    .chat-input:focus { border-color: #cba6f7; }
    .chat-input:disabled { opacity: 0.5; }
    .send-btn { padding: 8px 16px; background: #cba6f7; color: #1e1e2e; border: none; border-radius: 6px; cursor: pointer; font-family: inherit; font-size: 13px; font-weight: 600; }
    .send-btn:hover { background: #b4befe; }
    .send-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  </style>
</head>
<body>
  <div id=\"app\"></div>
  <script src=\"/app.js\"></script>
</body>
</html>"
}

// ============================================================================
// WebSocket handler
// ============================================================================

/// Custom messages the WebSocket process receives from the agent.
type WsCustomMessage {
  StateUpdate(payload: String)
}

/// WebSocket connection state.
type WsState {
  WsState(
    agent: Subject(AgentMessage),
    tree: Subject(AgentTreeMessage),
    registry: Subject(RegistryMessage),
    update_subject: Subject(String),
  )
}

fn upgrade_websocket(
  req: request.Request(mist.Connection),
  tree: Subject(AgentTreeMessage),
  registry: Subject(RegistryMessage),
  agent_id: String,
) -> response.Response(mist.ResponseData) {
  case agent_tree.get_agent(tree: tree, id: agent_id) {
    Error(_) ->
      response.new(404)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Agent not found: " <> agent_id)),
      )
    Ok(agent_subject) ->
      mist.websocket(
        request: req,
        handler: fn(state, msg, conn) {
          handle_ws_message(state: state, msg: msg, conn: conn)
        },
        on_init: fn(conn) { ws_init(agent_subject, tree, registry, conn) },
        on_close: fn(state) { ws_close(state) },
      )
  }
}

fn ws_init(
  agent_subject: Subject(AgentMessage),
  tree: Subject(AgentTreeMessage),
  registry: Subject(RegistryMessage),
  conn: mist.WebsocketConnection,
) -> #(WsState, Option(process.Selector(WsCustomMessage))) {
  // Create a subject for receiving state updates from the agent
  let update_subject = process.new_subject()

  // Build a selector that maps updates to WsCustomMessage
  let selector =
    process.new_selector()
    |> process.select_map(update_subject, fn(payload) { StateUpdate(payload:) })

  // Subscribe to agent updates
  agent.subscribe(subject: agent_subject, subscriber: update_subject)

  // Register with the broadcast registry
  registry_register(registry, update_subject)

  // Send initial state events so panels are populated immediately
  let initial_state =
    agent.get_current_state(subject: agent_subject, timeout: 5000)
  let _sent = mist.send_text_frame(conn, initial_state)

  let state =
    WsState(
      agent: agent_subject,
      tree: tree,
      registry: registry,
      update_subject: update_subject,
    )
  #(state, Some(selector))
}

fn ws_close(state: WsState) -> Nil {
  agent.unsubscribe(subject: state.agent, subscriber: state.update_subject)
  registry_unregister(state.registry, state.update_subject)
}

fn handle_ws_message(
  state state: WsState,
  msg msg: mist.WebsocketMessage(WsCustomMessage),
  conn conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsCustomMessage) {
  case msg {
    mist.Text(text) -> {
      handle_client_message(state: state, text: text)
      mist.continue(state)
    }
    mist.Custom(StateUpdate(payload)) -> {
      // Best-effort send — connection may have closed
      let _sent = mist.send_text_frame(conn, payload)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> {
      ws_close(state)
      mist.stop()
    }
  }
}

fn handle_client_message(state state: WsState, text text: String) -> Nil {
  case json.parse(text, protocol.client_command_decoder()) {
    Ok(protocol.SendUserMessage(text:)) -> {
      agent.send_message(subject: state.agent, text: text)
      Nil
    }
    Ok(protocol.SpawnRootAgent) -> {
      // TODO(phase4): implement root agent spawning via control WebSocket
      Nil
    }
    Ok(command) -> {
      // Map other ClientCommands to widget events
      dispatch_client_command(state, command)
    }
    Error(_) -> Nil
  }
}

fn dispatch_client_command(
  state: WsState,
  command: protocol.ClientCommand,
) -> Nil {
  // Map ClientCommand variants to the existing widget event dispatch
  let result = case command {
    protocol.SetGoal(text:) ->
      Ok(#(
        "set_goal",
        "{\"text\": " <> json.to_string(json.string(text)) <> "}",
      ))
    protocol.ClearGoal -> Ok(#("clear_goal", "{}"))
    protocol.SetSystemPrompt(text:) ->
      Ok(#(
        "set_system_prompt",
        "{\"text\": " <> json.to_string(json.string(text)) <> "}",
      ))
    protocol.ResetSystemPrompt -> Ok(#("reset_system_prompt", "{}"))
    protocol.CreateTask(description:) ->
      Ok(#(
        "create_task",
        "{\"description\": " <> json.to_string(json.string(description)) <> "}",
      ))
    protocol.StartTask(task_id:) ->
      Ok(#(
        "start_task",
        "{\"task_id\": " <> json.to_string(json.int(task_id)) <> "}",
      ))
    protocol.CloseCurrentTask -> Ok(#("close_current_task", "{}"))
    protocol.TaskMemoryCmd(text:) ->
      Ok(#(
        "task_memory_cmd",
        "{\"text\": " <> json.to_string(json.string(text)) <> "}",
      ))
    protocol.PickTask(task_id:) ->
      Ok(#(
        "pick_task",
        "{\"task_id\": " <> json.to_string(json.int(task_id)) <> "}",
      ))
    protocol.RemoveTask(task_id:) ->
      Ok(#(
        "remove_task",
        "{\"task_id\": " <> json.to_string(json.int(task_id)) <> "}",
      ))
    protocol.EditMemory(task_id:, index:, new_text:) ->
      Ok(#(
        "edit_memory",
        "{\"task_id\": "
          <> json.to_string(json.int(task_id))
          <> ", \"index\": "
          <> json.to_string(json.int(index))
          <> ", \"new_text\": "
          <> json.to_string(json.string(new_text))
          <> "}",
      ))
    protocol.RemoveMemory(task_id:, index:) ->
      Ok(#(
        "remove_memory",
        "{\"task_id\": "
          <> json.to_string(json.int(task_id))
          <> ", \"index\": "
          <> json.to_string(json.int(index))
          <> "}",
      ))
    protocol.ToggleTaskExpanded(task_id:) ->
      Ok(#(
        "toggle_task_expanded",
        "{\"task_id\": " <> json.to_string(json.int(task_id)) <> "}",
      ))
    protocol.OpenDirectory(path:) ->
      Ok(#(
        "open_directory",
        "{\"path\": " <> json.to_string(json.string(path)) <> "}",
      ))
    protocol.CloseDirectory(path:) ->
      Ok(#(
        "close_directory",
        "{\"path\": " <> json.to_string(json.string(path)) <> "}",
      ))
    protocol.ReadFile(path:) ->
      Ok(#(
        "read_file",
        "{\"path\": " <> json.to_string(json.string(path)) <> "}",
      ))
    protocol.CloseReadFile(path:) ->
      Ok(#(
        "close_read_file",
        "{\"path\": " <> json.to_string(json.string(path)) <> "}",
      ))
    // SendUserMessage and SpawnRootAgent are handled above
    protocol.SendUserMessage(..) | protocol.SpawnRootAgent -> Error(Nil)
  }
  case result {
    Ok(#(event_name, args_json)) -> {
      agent.dispatch_event(
        subject: state.agent,
        event_name: event_name,
        args_json: args_json,
      )
      Nil
    }
    Error(_) -> Nil
  }
}
