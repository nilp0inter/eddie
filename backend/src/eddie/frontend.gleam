/// Browser frontend template — the HTML/CSS/JS served at GET /.
///
/// This is a single-page app with a Catppuccin-themed chat UI,
/// VS Code-style activity bar for widget panels, WebSocket auto-reconnect,
/// and client-side markdown rendering.
pub fn index_html() -> String {
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
