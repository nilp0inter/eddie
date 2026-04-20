/// HTTP server and WebSocket handler — serves the Eddie web UI.
///
/// Uses mist for HTTP serving and WebSocket connections.
///
/// Two WebSocket endpoints:
/// - /ws/control — system-level: tree change events, root agent spawning
/// - /ws/<agent_id> — per-agent: state updates, user messages, widget events
import eddie/agent.{type AgentMessage}
import eddie/agent_tree.{type AgentTreeMessage}
import eddie_shared/agent_info
import eddie_shared/protocol
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json
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
// Server start
// ============================================================================

/// Start the HTTP + WebSocket server.
pub fn start(
  config config: ServerConfig,
  tree tree: Subject(AgentTreeMessage),
) -> Result(actor.Started(Supervisor), actor.StartError) {
  mist.new(fn(req) { handle_request(req, tree) })
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
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [] -> serve_index()
    ["app.js"] -> serve_app_js()
    ["agents"] -> serve_agents(tree)
    ["ws", "control"] -> upgrade_control_websocket(req, tree)
    ["ws", agent_id] -> upgrade_agent_websocket(req, tree, agent_id)
    _ -> serve_index()
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
    .task-item.clickable { cursor: pointer; border-radius: 4px; padding: 4px; }
    .task-item.clickable:hover { background: #313244; }
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
    .msg { margin-bottom: 12px; display: flex; flex-direction: column; }
    .msg-role { font-size: 11px; font-weight: 600; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
    .msg-user, .msg-system { align-items: flex-end; }
    .msg-assistant { align-items: flex-start; }
    .msg-user .msg-content { background: #1e66f5; color: #ffffff; border-radius: 12px 12px 2px 12px; }
    .msg-system .msg-content { background: #1e66f5cc; color: #ffffff; border-radius: 12px 12px 2px 12px; }
    .msg-assistant .msg-content { background: #313244; color: #cdd6f4; border-radius: 12px 12px 12px 2px; }
    .msg-user .msg-role { color: #89b4fa; }
    .msg-system .msg-role { color: #94e2d5; }
    .msg-assistant .msg-role { color: #cba6f7; }
    .msg-content { max-width: 80%; font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; padding: 8px 12px; text-align: left; }
    .msg-content p { margin-bottom: 8px; }
    .msg-content p:last-child { margin-bottom: 0; }
    .tool-calls { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
    .tool-badge { font-size: 10px; padding: 2px 6px; border-radius: 4px; background: #31324480; color: #a6adc8; }
    .tool-badge.running { background: #cba6f71a; color: #cba6f7; }
    .msg-tool-results { margin-bottom: 12px; max-width: 80%; }
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
    .back-btn { background: none; border: none; color: #89b4fa; cursor: pointer; font-family: inherit; font-size: 13px; padding: 4px 8px; border-radius: 4px; }
    .back-btn:hover { background: #313244; }
    .parent-btn { background: none; border: none; color: #94e2d5; cursor: pointer; font-family: inherit; font-size: 13px; padding: 4px 8px; border-radius: 4px; }
    .parent-btn:hover { background: #313244; }
    .editable-label { cursor: pointer; border-bottom: 1px dashed transparent; }
    .editable-label:hover { border-bottom-color: #6c7086; }
    .label-edit { display: flex; align-items: center; gap: 6px; }
    .label-edit-input { padding: 2px 8px; background: #313244; color: #cdd6f4; border: 1px solid #cba6f7; border-radius: 4px; font-family: inherit; font-size: 16px; font-weight: bold; outline: none; width: 200px; }
    .label-edit-ok { font-size: 11px; padding: 3px 8px; background: #a6e3a1; color: #1e1e2e; border: none; border-radius: 4px; cursor: pointer; font-family: inherit; font-weight: 600; }
    .label-edit-cancel { font-size: 11px; padding: 3px 8px; background: none; color: #6c7086; border: 1px solid #45475a; border-radius: 4px; cursor: pointer; font-family: inherit; }
    .agent-id-label { font-size: 11px; color: #6c7086; margin-left: 8px; flex: 1; }
    .agent-list-page { flex: 1; padding: 24px; overflow-y: auto; }
    .agent-list-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
    .agent-list-header h2 { font-size: 18px; color: #cdd6f4; }
    .agent-list-empty { text-align: center; padding: 48px 0; }
    .agent-list { display: flex; flex-direction: column; gap: 8px; }
    .agent-card { padding: 12px 16px; background: #181825; border: 1px solid #313244; border-radius: 8px; cursor: pointer; }
    .agent-card:hover { border-color: #cba6f7; }
    .agent-card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px; }
    .agent-card-label { font-size: 14px; font-weight: 600; color: #cdd6f4; }
    .agent-card-status { font-size: 10px; padding: 2px 6px; border-radius: 4px; }
    .agent-card-status.status-idle { color: #6c7086; background: #6c70861a; }
    .agent-card-status.status-running { color: #f9e2af; background: #f9e2af1a; }
    .agent-card-status.status-completed { color: #a6e3a1; background: #a6e3a11a; }
    .agent-card-status.status-error { color: #f38ba8; background: #f38ba81a; }
    .agent-card-id { font-size: 11px; color: #6c7086; }
    .agent-card-children { font-size: 11px; color: #a6adc8; margin-top: 4px; }
    .agent-card-subtree { margin-top: 8px; margin-left: 16px; display: flex; flex-direction: column; gap: 4px; }
    .agent-card-subtree .agent-card { padding: 8px 12px; }
  </style>
</head>
<body>
  <div id=\"app\"></div>
  <script src=\"/app.js\"></script>
</body>
</html>"
}

// ============================================================================
// Control WebSocket — system-level events and commands
// ============================================================================

/// Custom messages for the control WebSocket process.
type ControlWsCustomMessage {
  TreeUpdate(payload: String)
}

/// Control WebSocket state.
type ControlWsState {
  ControlWsState(
    tree: Subject(AgentTreeMessage),
    update_subject: Subject(String),
  )
}

fn upgrade_control_websocket(
  req: request.Request(mist.Connection),
  tree: Subject(AgentTreeMessage),
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    handler: fn(state, msg, conn) {
      handle_control_ws_message(state: state, msg: msg, conn: conn)
    },
    on_init: fn(conn) { control_ws_init(tree, conn) },
    on_close: fn(state) { control_ws_close(state) },
  )
}

fn control_ws_init(
  tree: Subject(AgentTreeMessage),
  conn: mist.WebsocketConnection,
) -> #(ControlWsState, Option(process.Selector(ControlWsCustomMessage))) {
  let update_subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(update_subject, fn(payload) { TreeUpdate(payload:) })

  // Subscribe to tree change events
  agent_tree.subscribe_tree(tree: tree, subscriber: update_subject)

  // Send initial tree state
  let roots = agent_tree.get_tree(tree: tree)
  let event = protocol.AgentTreeChanged(roots: roots)
  let payload = protocol.server_events_to_json_string([event])
  let _sent = mist.send_text_frame(conn, payload)

  let state = ControlWsState(tree: tree, update_subject: update_subject)
  #(state, Some(selector))
}

fn control_ws_close(state: ControlWsState) -> Nil {
  agent_tree.unsubscribe_tree(
    tree: state.tree,
    subscriber: state.update_subject,
  )
}

fn handle_control_ws_message(
  state state: ControlWsState,
  msg msg: mist.WebsocketMessage(ControlWsCustomMessage),
  conn conn: mist.WebsocketConnection,
) -> mist.Next(ControlWsState, ControlWsCustomMessage) {
  case msg {
    mist.Text(text) -> {
      handle_control_client_message(state: state, text: text, conn: conn)
      mist.continue(state)
    }
    mist.Custom(TreeUpdate(payload)) -> {
      let _sent = mist.send_text_frame(conn, payload)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> {
      control_ws_close(state)
      mist.stop()
    }
  }
}

fn handle_control_client_message(
  state state: ControlWsState,
  text text: String,
  conn conn: mist.WebsocketConnection,
) -> Nil {
  case json.parse(text, protocol.client_command_decoder()) {
    Ok(protocol.RenameAgent(agent_id:, label:)) -> {
      agent_tree.rename_agent(tree: state.tree, agent_id:, label:)
    }
    Ok(protocol.SpawnRootAgent) -> {
      let id = generate_uuid()
      let label = "Agent"
      let system_prompt =
        "You are Eddie, a helpful AI assistant. You work within a task-based workflow where your conversation is managed through tasks. Follow the task protocol carefully: create tasks, record memories aggressively, and close tasks when done."
      case
        agent_tree.spawn_root(
          tree: state.tree,
          id: id,
          label: label,
          system_prompt: system_prompt,
        )
      {
        Ok(_) -> Nil
        Error(_) -> {
          let event =
            protocol.AgentSpawnFailed(id: id, reason: "Failed to create agent")
          let payload = protocol.server_events_to_json_string([event])
          let _sent = mist.send_text_frame(conn, payload)
          Nil
        }
      }
    }
    _ -> Nil
  }
}

// ============================================================================
// Agent WebSocket — per-agent state updates and commands
// ============================================================================

/// Custom messages the agent WebSocket process receives.
type AgentWsCustomMessage {
  AgentStateUpdate(payload: String)
}

/// Agent WebSocket connection state.
type AgentWsState {
  AgentWsState(
    agent: Subject(AgentMessage),
    tree: Subject(AgentTreeMessage),
    update_subject: Subject(String),
  )
}

fn upgrade_agent_websocket(
  req: request.Request(mist.Connection),
  tree: Subject(AgentTreeMessage),
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
          handle_agent_ws_message(state: state, msg: msg, conn: conn)
        },
        on_init: fn(conn) { agent_ws_init(agent_subject, tree, conn) },
        on_close: fn(state) { agent_ws_close(state) },
      )
  }
}

fn agent_ws_init(
  agent_subject: Subject(AgentMessage),
  tree: Subject(AgentTreeMessage),
  conn: mist.WebsocketConnection,
) -> #(AgentWsState, Option(process.Selector(AgentWsCustomMessage))) {
  let update_subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(update_subject, fn(payload) {
      AgentStateUpdate(payload:)
    })

  // Subscribe to agent updates
  agent.subscribe(subject: agent_subject, subscriber: update_subject)

  // Send initial state events so panels are populated immediately
  let initial_state =
    agent.get_current_state(subject: agent_subject, timeout: 5000)
  let _sent = mist.send_text_frame(conn, initial_state)

  let state =
    AgentWsState(
      agent: agent_subject,
      tree: tree,
      update_subject: update_subject,
    )
  #(state, Some(selector))
}

fn agent_ws_close(state: AgentWsState) -> Nil {
  agent.unsubscribe(subject: state.agent, subscriber: state.update_subject)
}

fn handle_agent_ws_message(
  state state: AgentWsState,
  msg msg: mist.WebsocketMessage(AgentWsCustomMessage),
  conn conn: mist.WebsocketConnection,
) -> mist.Next(AgentWsState, AgentWsCustomMessage) {
  case msg {
    mist.Text(text) -> {
      handle_agent_client_message(state: state, text: text)
      mist.continue(state)
    }
    mist.Custom(AgentStateUpdate(payload)) -> {
      let _sent = mist.send_text_frame(conn, payload)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> {
      agent_ws_close(state)
      mist.stop()
    }
  }
}

fn handle_agent_client_message(
  state state: AgentWsState,
  text text: String,
) -> Nil {
  case json.parse(text, protocol.client_command_decoder()) {
    Ok(protocol.SendUserMessage(text:)) -> {
      agent.send_message(subject: state.agent, text: text)
      Nil
    }
    Ok(command) -> {
      dispatch_agent_command(state, command)
    }
    Error(_) -> Nil
  }
}

fn dispatch_agent_command(
  state: AgentWsState,
  command: protocol.ClientCommand,
) -> Nil {
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
    // SpawnRootAgent/RenameAgent handled by control WS, SendUserMessage above
    protocol.SendUserMessage(..)
    | protocol.SpawnRootAgent
    | protocol.RenameAgent(..) -> Error(Nil)
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

// ============================================================================
// FFI
// ============================================================================

@external(erlang, "eddie_ffi", "generate_uuid")
fn generate_uuid() -> String
