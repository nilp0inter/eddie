/// HTTP server and WebSocket handler — serves the Eddie web UI.
///
/// Uses mist for HTTP serving and WebSocket connections.
/// Each WebSocket connection subscribes to the agent for HTML updates.
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}

import eddie/agent.{type AgentMessage, type TurnResult}
import mist

/// Configuration for the web server.
pub type ServerConfig {
  ServerConfig(port: Int)
}

/// Start the HTTP + WebSocket server.
pub fn start(
  config config: ServerConfig,
  agent agent: Subject(AgentMessage),
) -> Result(actor.Started(Supervisor), actor.StartError) {
  mist.new(fn(req) { handle_request(req, agent) })
  |> mist.port(config.port)
  |> mist.bind("0.0.0.0")
  |> mist.start
}

// ============================================================================
// HTTP request routing
// ============================================================================

fn handle_request(
  req: request.Request(mist.Connection),
  agent: Subject(AgentMessage),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [] -> serve_index()
    ["ws"] -> upgrade_websocket(req, agent)
    _ -> not_found()
  }
}

fn serve_index() -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index_html())))
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
}

// ============================================================================
// WebSocket handler
// ============================================================================

/// Custom messages the WebSocket process receives from other processes.
type WsCustomMessage {
  HtmlUpdate(payload: String)
  TurnComplete(result: TurnResult)
}

/// WebSocket connection state.
type WsState {
  WsState(
    agent: Subject(AgentMessage),
    update_subject: Subject(String),
    turn_result_subject: Subject(TurnResult),
  )
}

fn upgrade_websocket(
  req: request.Request(mist.Connection),
  agent: Subject(AgentMessage),
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    handler: fn(state, msg, conn) {
      handle_ws_message(state: state, msg: msg, conn: conn)
    },
    on_init: fn(_conn) { ws_init(agent) },
    on_close: fn(state) { ws_close(state) },
  )
}

fn ws_init(
  agent: Subject(AgentMessage),
) -> #(WsState, Option(process.Selector(WsCustomMessage))) {
  // Create subjects for receiving updates from the agent
  let update_subject = process.new_subject()
  let turn_result_subject = process.new_subject()

  // Build a selector that maps both subjects to WsCustomMessage
  let selector =
    process.new_selector()
    |> process.select_map(update_subject, fn(payload) { HtmlUpdate(payload:) })
    |> process.select_map(turn_result_subject, fn(result) {
      TurnComplete(result:)
    })

  // Subscribe to agent updates
  agent.subscribe(subject: agent, subscriber: update_subject)

  let state =
    WsState(
      agent: agent,
      update_subject: update_subject,
      turn_result_subject: turn_result_subject,
    )
  #(state, Some(selector))
}

fn ws_close(state: WsState) -> Nil {
  agent.unsubscribe(subject: state.agent, subscriber: state.update_subject)
}

fn handle_ws_message(
  state state: WsState,
  msg msg: mist.WebsocketMessage(WsCustomMessage),
  conn conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsCustomMessage) {
  case msg {
    mist.Text(text) -> {
      handle_client_message(state: state, text: text, conn: conn)
      mist.continue(state)
    }
    mist.Custom(HtmlUpdate(payload)) -> {
      // Best-effort send — connection may have closed
      let _sent = mist.send_text_frame(conn, payload)
      mist.continue(state)
    }
    mist.Custom(TurnComplete(turn_result)) -> {
      let response_json = turn_result_to_json(turn_result)
      let _sent = mist.send_text_frame(conn, response_json)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> {
      ws_close(state)
      mist.stop()
    }
  }
}

fn handle_client_message(
  state state: WsState,
  text text: String,
  conn conn: mist.WebsocketConnection,
) -> Nil {
  let user_input_decoder = decode.at(["user_input"], decode.string)
  let widget_event_decoder = {
    use event_name <- decode.field("event_name", decode.string)
    use args_json <- decode.field("args_json", decode.string)
    decode.success(#(event_name, args_json))
  }

  case json.parse(text, user_input_decoder) {
    Ok(user_text) -> {
      // Best-effort send of thinking indicator
      let _sent = mist.send_text_frame(conn, "{\"type\":\"turn_start\"}")
      send_run_turn(
        agent_subject: state.agent,
        text: user_text,
        result_subject: state.turn_result_subject,
      )
      Nil
    }
    Error(_) ->
      case json.parse(text, decode.at(["widget_event"], widget_event_decoder)) {
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
}

/// Spawn a helper process that calls agent.run_turn (blocking) and
/// forwards the result to the given subject. This avoids needing to
/// construct opaque AgentMessage values directly.
fn send_run_turn(
  agent_subject agent_subject: Subject(AgentMessage),
  text text: String,
  result_subject result_subject: Subject(TurnResult),
) -> Nil {
  let _pid =
    process.spawn(fn() {
      // 5 minute timeout for a turn
      let turn_result =
        agent.run_turn(subject: agent_subject, text: text, timeout: 300_000)
      process.send(result_subject, turn_result)
    })
  Nil
}

fn turn_result_to_json(result: TurnResult) -> String {
  case result {
    agent.TurnSuccess(text) ->
      "{\"type\":\"turn_end\",\"success\":true,\"text\":"
      <> json.to_string(json.string(text))
      <> "}"
    agent.TurnError(reason) ->
      "{\"type\":\"turn_end\",\"success\":false,\"error\":"
      <> json.to_string(json.string(reason))
      <> "}"
  }
}

// ============================================================================
// Inline HTML frontend
// ============================================================================

fn index_html() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Eddie</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #1e1e2e; color: #cdd6f4; height: 100vh;
      display: flex; flex-direction: column;
    }
    header {
      background: #181825; padding: 12px 20px; border-bottom: 1px solid #313244;
      display: flex; align-items: center; gap: 12px;
    }
    header h1 { font-size: 18px; color: #cba6f7; }
    header .status { font-size: 12px; color: #6c7086; }
    .main { flex: 1; display: flex; overflow: hidden; }
    .sidebar {
      width: 280px; background: #181825; border-right: 1px solid #313244;
      overflow-y: auto; padding: 12px;
    }
    .sidebar h2 { font-size: 13px; color: #6c7086; text-transform: uppercase; margin-bottom: 8px; }
    .chat-area { flex: 1; display: flex; flex-direction: column; }
    .messages {
      flex: 1; overflow-y: auto; padding: 16px; display: flex;
      flex-direction: column; gap: 12px;
    }
    .message {
      max-width: 80%; padding: 10px 14px; border-radius: 12px;
      line-height: 1.5; white-space: pre-wrap; word-wrap: break-word;
    }
    .message.user {
      align-self: flex-end; background: #45475a; color: #cdd6f4;
    }
    .message.assistant {
      align-self: flex-start; background: #313244; color: #cdd6f4;
    }
    .message.error {
      align-self: center; background: #f38ba8; color: #1e1e2e;
      font-size: 13px;
    }
    .thinking {
      align-self: flex-start; color: #6c7086; font-style: italic;
      padding: 10px 14px; display: none;
    }
    .thinking.active { display: block; }
    .input-area {
      padding: 12px 16px; background: #181825;
      border-top: 1px solid #313244;
    }
    .input-area form { display: flex; gap: 8px; }
    .input-area input {
      flex: 1; padding: 10px 14px; background: #313244; border: 1px solid #45475a;
      border-radius: 8px; color: #cdd6f4; font-size: 14px; outline: none;
    }
    .input-area input:focus { border-color: #cba6f7; }
    .input-area input:disabled { opacity: 0.5; }
    .input-area button {
      padding: 10px 20px; background: #cba6f7; color: #1e1e2e;
      border: none; border-radius: 8px; font-weight: 600; cursor: pointer;
    }
    .input-area button:hover { background: #b4befe; }
    .input-area button:disabled { opacity: 0.5; cursor: not-allowed; }
    .widget-panel { padding: 8px; font-size: 13px; }
    .widget-panel > div { margin-bottom: 8px; }
  </style>
</head>
<body>
  <header>
    <h1>Eddie</h1>
    <span class=\"status\" id=\"connection-status\">Connecting...</span>
  </header>
  <div class=\"main\">
    <div class=\"sidebar\">
      <h2>Widgets</h2>
      <div class=\"widget-panel\">
        <div id=\"widget-system_prompt\"></div>
        <div id=\"widget-conversation_log\"></div>
      </div>
    </div>
    <div class=\"chat-area\">
      <div class=\"messages\" id=\"messages\"></div>
      <div class=\"thinking\" id=\"thinking\">Eddie is thinking...</div>
      <div class=\"input-area\">
        <form id=\"chat-form\">
          <input type=\"text\" id=\"chat-input\" placeholder=\"Type a message...\" autocomplete=\"off\" />
          <button type=\"submit\" id=\"send-btn\">Send</button>
        </form>
      </div>
    </div>
  </div>
  <script>
    const messagesEl = document.getElementById('messages');
    const thinkingEl = document.getElementById('thinking');
    const chatForm = document.getElementById('chat-form');
    const chatInput = document.getElementById('chat-input');
    const sendBtn = document.getElementById('send-btn');
    const statusEl = document.getElementById('connection-status');
    let ws;

    function connect() {
      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(protocol + '//' + location.host + '/ws');

      ws.onopen = () => {
        statusEl.textContent = 'Connected';
        statusEl.style.color = '#a6e3a1';
      };

      ws.onclose = () => {
        statusEl.textContent = 'Disconnected — reconnecting...';
        statusEl.style.color = '#f38ba8';
        setTimeout(connect, 2000);
      };

      ws.onmessage = (event) => {
        const data = event.data;
        // Try JSON first
        try {
          const msg = JSON.parse(data);
          if (msg.type === 'turn_start') {
            thinkingEl.classList.add('active');
            chatInput.disabled = true;
            sendBtn.disabled = true;
            return;
          }
          if (msg.type === 'turn_end') {
            thinkingEl.classList.remove('active');
            chatInput.disabled = false;
            sendBtn.disabled = false;
            chatInput.focus();
            if (msg.success) {
              addMessage('assistant', msg.text);
            } else {
              addMessage('error', 'Error: ' + msg.error);
            }
            return;
          }
        } catch (e) {}

        // HTML fragment update — find elements with data-swap-oob
        const temp = document.createElement('div');
        temp.innerHTML = data;
        const children = temp.querySelectorAll('[data-swap-oob]');
        children.forEach(el => {
          const target = document.getElementById(el.id);
          if (target) {
            target.innerHTML = el.innerHTML;
          }
        });
      };
    }

    function addMessage(role, text) {
      const div = document.createElement('div');
      div.className = 'message ' + role;
      div.textContent = text;
      messagesEl.appendChild(div);
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    chatForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const text = chatInput.value.trim();
      if (!text || !ws || ws.readyState !== WebSocket.OPEN) return;
      addMessage('user', text);
      ws.send(JSON.stringify({ user_input: text }));
      chatInput.value = '';
    });

    connect();
    chatInput.focus();
  </script>
</body>
</html>"
}
