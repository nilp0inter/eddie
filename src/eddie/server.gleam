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
    on_init: fn(conn) { ws_init(agent, conn) },
    on_close: fn(state) { ws_close(state) },
  )
}

fn ws_init(
  agent_subject: Subject(AgentMessage),
  conn: mist.WebsocketConnection,
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
  agent.subscribe(subject: agent_subject, subscriber: update_subject)

  // Send initial widget HTML so panels are populated immediately
  let initial_html =
    agent.get_current_html(subject: agent_subject, timeout: 5000)
  let _sent = mist.send_text_frame(conn, initial_html)

  let state =
    WsState(
      agent: agent_subject,
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

    /* Activity bar */
    .activity-bar {
      width: 48px; background: #11111b; border-right: 1px solid #313244;
      display: flex; flex-direction: column; align-items: center;
      padding-top: 4px; flex-shrink: 0;
    }
    .activity-btn {
      width: 48px; height: 48px; background: none; border: none;
      color: #6c7086; font-size: 20px; cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      position: relative; border-left: 2px solid transparent;
    }
    .activity-btn:hover { color: #cdd6f4; }
    .activity-btn.active { color: #cdd6f4; border-left-color: #cba6f7; }
    .activity-btn .badge {
      position: absolute; top: 6px; right: 8px;
      width: 8px; height: 8px; background: #f38ba8;
      border-radius: 50%; display: none;
    }
    .activity-btn .badge.visible { display: block; }

    /* Side panel */
    .side-panel {
      width: 320px; background: #181825; border-right: 1px solid #313244;
      overflow-y: auto; padding: 12px; display: none; flex-shrink: 0;
    }
    .side-panel.open { display: block; }
    .side-panel .widget-pane { display: none; font-size: 13px; }
    .side-panel .widget-pane.active { display: block; }

    /* Widget styling */
    .side-panel h3 { font-size: 14px; color: #cba6f7; margin-bottom: 8px; }
    .side-panel input, .side-panel textarea {
      background: #313244; border: 1px solid #45475a; border-radius: 4px;
      color: #cdd6f4; padding: 6px 8px; font-size: 13px; outline: none;
      font-family: inherit;
    }
    .side-panel input:focus, .side-panel textarea:focus { border-color: #cba6f7; }
    .side-panel button {
      background: #45475a; border: none; border-radius: 4px;
      color: #cdd6f4; padding: 4px 10px; font-size: 12px;
      cursor: pointer; margin: 2px;
    }
    .side-panel button:hover { background: #585b70; }
    .side-panel button[disabled] { opacity: 0.4; cursor: not-allowed; }
    .side-panel em { color: #6c7086; }
    .side-panel ul { list-style: none; padding-left: 8px; }
    .side-panel li { padding: 2px 0; }
    .side-panel pre {
      background: #11111b; padding: 8px; border-radius: 4px;
      overflow-x: auto; font-size: 12px; max-height: 300px; overflow-y: auto;
    }

    /* Chat area */
    .chat-area { flex: 1; display: flex; flex-direction: column; }
    .messages {
      flex: 1; overflow-y: auto; padding: 16px; display: flex;
      flex-direction: column; gap: 12px;
    }
    .message {
      max-width: 80%; padding: 10px 14px; border-radius: 12px;
      line-height: 1.5; white-space: pre-wrap; word-wrap: break-word;
    }
    .message.user { align-self: flex-end; background: #45475a; color: #cdd6f4; }
    .message.assistant { align-self: flex-start; background: #313244; color: #cdd6f4; }
    .message.error {
      align-self: center; background: #f38ba8; color: #1e1e2e; font-size: 13px;
    }
    .thinking {
      align-self: flex-start; color: #6c7086; font-style: italic;
      padding: 10px 14px; display: none;
    }
    .thinking.active { display: block; }
    .input-area {
      padding: 12px 16px; background: #181825; border-top: 1px solid #313244;
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

    /* Tool calls and results */
    .tool-call {
      max-width: 90%; padding: 6px 10px; border-radius: 8px;
      background: #1e3a2f; color: #a6e3a1; font-size: 13px;
      cursor: pointer;
    }
    .tool-call summary { font-family: monospace; font-size: 12px; }
    .tool-call pre {
      margin-top: 4px; padding: 6px; background: #11111b;
      border-radius: 4px; font-size: 11px; overflow-x: auto;
      max-height: 200px; overflow-y: auto; color: #cdd6f4;
    }
    .tool-result {
      max-width: 90%; padding: 6px 10px; border-radius: 8px;
      background: #1e2d3a; font-size: 13px;
    }
    .tool-result-label {
      font-family: monospace; font-size: 12px; color: #89b4fa;
    }
    .tool-result pre {
      margin-top: 4px; padding: 6px; background: #11111b;
      border-radius: 4px; font-size: 11px; overflow-x: auto;
      max-height: 200px; overflow-y: auto;
    }

    /* Markdown in messages */
    .message.assistant code {
      background: #11111b; padding: 1px 4px; border-radius: 3px;
      font-family: monospace; font-size: 13px;
    }
    .message.assistant pre {
      background: #11111b; padding: 8px; border-radius: 4px;
      margin: 4px 0; overflow-x: auto;
    }
    .message.assistant pre code { background: none; padding: 0; }
    .message.assistant h2, .message.assistant h3, .message.assistant h4 {
      margin: 8px 0 4px; color: #cba6f7;
    }
    .message.assistant li { margin-left: 16px; list-style: disc; }
    .message.assistant strong { color: #f5e0dc; }
  </style>
</head>
<body>
  <header>
    <h1>Eddie</h1>
    <span class=\"status\" id=\"connection-status\">Connecting...</span>
  </header>
  <div class=\"main\">
    <div class=\"activity-bar\">
      <button class=\"activity-btn\" data-panel=\"widget-system_prompt\" onclick=\"togglePanel('widget-system_prompt')\" title=\"System Prompt\">
        <span>&#9881;</span><span class=\"badge\" id=\"badge-widget-system_prompt\"></span>
      </button>
      <button class=\"activity-btn\" data-panel=\"widget-goal\" onclick=\"togglePanel('widget-goal')\" title=\"Goal\">
        <span>&#127919;</span><span class=\"badge\" id=\"badge-widget-goal\"></span>
      </button>
      <button class=\"activity-btn\" data-panel=\"widget-file_explorer\" onclick=\"togglePanel('widget-file_explorer')\" title=\"File Explorer\">
        <span>&#128193;</span><span class=\"badge\" id=\"badge-widget-file_explorer\"></span>
      </button>
      <button class=\"activity-btn\" data-panel=\"widget-conversation_log\" onclick=\"togglePanel('widget-conversation_log')\" title=\"Tasks\">
        <span>&#128203;</span><span class=\"badge\" id=\"badge-widget-conversation_log\"></span>
      </button>
      <button class=\"activity-btn\" data-panel=\"widget-token_usage\" onclick=\"togglePanel('widget-token_usage')\" title=\"Token Usage\">
        <span>&#128202;</span><span class=\"badge\" id=\"badge-widget-token_usage\"></span>
      </button>
    </div>
    <div class=\"side-panel\" id=\"side-panel\">
      <div class=\"widget-pane\" id=\"widget-system_prompt\"></div>
      <div class=\"widget-pane\" id=\"widget-goal\"></div>
      <div class=\"widget-pane\" id=\"widget-file_explorer\"></div>
      <div class=\"widget-pane\" id=\"widget-conversation_log\"></div>
      <div class=\"widget-pane\" id=\"widget-token_usage\"></div>
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
    const sidePanel = document.getElementById('side-panel');
    let ws;
    let activePanel = null;

    function togglePanel(widgetId) {
      const btns = document.querySelectorAll('.activity-btn');
      if (activePanel === widgetId) {
        // Close panel
        activePanel = null;
        sidePanel.classList.remove('open');
        btns.forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.widget-pane').forEach(p => p.classList.remove('active'));
      } else {
        // Open/switch panel
        activePanel = widgetId;
        sidePanel.classList.add('open');
        btns.forEach(b => {
          b.classList.toggle('active', b.dataset.panel === widgetId);
        });
        document.querySelectorAll('.widget-pane').forEach(p => {
          p.classList.toggle('active', p.id === widgetId);
        });
        // Clear badge
        const badge = document.getElementById('badge-' + widgetId);
        if (badge) badge.classList.remove('visible');
      }
    }

    function notifyWidgetUpdate(widgetId) {
      if (activePanel !== widgetId) {
        const badge = document.getElementById('badge-' + widgetId);
        if (badge) badge.classList.add('visible');
      }
    }

    let connectTimeout;

    function connect() {
      // Clean up any previous connection stuck in CONNECTING state
      if (ws) {
        ws.onopen = null;
        ws.onclose = null;
        ws.onerror = null;
        ws.onmessage = null;
        if (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN) {
          ws.close();
        }
      }
      clearTimeout(connectTimeout);

      statusEl.textContent = 'Connecting...';
      statusEl.style.color = '#6c7086';

      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(protocol + '//' + location.host + '/ws');

      // If the connection doesn't open within 5s, force-close and retry
      connectTimeout = setTimeout(() => {
        if (ws.readyState === WebSocket.CONNECTING) {
          ws.close();
        }
      }, 5000);

      ws.onopen = () => {
        clearTimeout(connectTimeout);
        statusEl.textContent = 'Connected';
        statusEl.style.color = '#a6e3a1';
      };

      ws.onclose = () => {
        clearTimeout(connectTimeout);
        statusEl.textContent = 'Disconnected \\u2014 reconnecting...';
        statusEl.style.color = '#f38ba8';
        setTimeout(connect, 2000);
      };

      ws.onmessage = (event) => {
        const data = event.data;
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
          if (msg.type === 'tool_call') {
            addToolCall(msg.name, msg.args);
            return;
          }
          if (msg.type === 'tool_result') {
            addToolResult(msg.name, msg.result);
            return;
          }
        } catch (e) {}

        // HTML fragment update
        const temp = document.createElement('div');
        temp.innerHTML = data;
        const children = temp.querySelectorAll('[data-swap-oob]');
        children.forEach(el => {
          const target = document.getElementById(el.id);
          if (target) {
            target.innerHTML = el.innerHTML;
            notifyWidgetUpdate(el.id);
          }
        });
      };
    }

    function renderMarkdown(text) {
      // Escape HTML first
      let s = text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      // Fenced code blocks
      s = s.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, function(m, lang, code) {
        return '<pre><code>' + code.trim() + '</code></pre>';
      });
      // Inline code
      s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
      // Bold
      s = s.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
      // Italic
      s = s.replace(/\\*([^*]+)\\*/g, '<em>$1</em>');
      // Headers
      s = s.replace(/^### (.+)$/gm, '<h4>$1</h4>');
      s = s.replace(/^## (.+)$/gm, '<h3>$1</h3>');
      s = s.replace(/^# (.+)$/gm, '<h2>$1</h2>');
      // Unordered lists
      s = s.replace(/^- (.+)$/gm, '<li>$1</li>');
      return s;
    }

    function addMessage(role, text) {
      const div = document.createElement('div');
      div.className = 'message ' + role;
      if (role === 'assistant') {
        div.innerHTML = renderMarkdown(text);
      } else {
        div.textContent = text;
      }
      messagesEl.appendChild(div);
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function addToolCall(name, args) {
      const details = document.createElement('details');
      details.className = 'tool-call';
      const summary = document.createElement('summary');
      summary.textContent = name + '(' + (args.length > 60 ? args.substring(0,60) + '...' : args) + ')';
      details.appendChild(summary);
      const pre = document.createElement('pre');
      try { pre.textContent = JSON.stringify(JSON.parse(args), null, 2); }
      catch(e) { pre.textContent = args; }
      details.appendChild(pre);
      messagesEl.appendChild(details);
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function addToolResult(name, result) {
      const div = document.createElement('div');
      div.className = 'tool-result';
      const label = document.createElement('span');
      label.className = 'tool-result-label';
      label.textContent = name + ' result:';
      div.appendChild(label);
      const pre = document.createElement('pre');
      pre.textContent = result.length > 500 ? result.substring(0, 500) + '...' : result;
      div.appendChild(pre);
      messagesEl.appendChild(div);
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function sendWidgetEvent(eventName, args) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          widget_event: { event_name: eventName, args_json: JSON.stringify(args) }
        }));
      }
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
