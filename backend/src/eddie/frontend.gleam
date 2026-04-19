/// Minimal browser frontend — logs JSON domain events to the console.
///
/// This is a temporary stub until the Lustre SPA frontend is built in Phase 4.
/// It connects via WebSocket and displays raw JSON events.
pub fn index_html() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Eddie — Event Log</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: monospace;
      background: #1e1e2e; color: #cdd6f4; height: 100vh;
      display: flex; flex-direction: column; padding: 20px;
    }
    h1 { color: #cba6f7; margin-bottom: 12px; }
    .status { font-size: 12px; color: #6c7086; margin-bottom: 16px; }
    #log {
      flex: 1; overflow-y: auto; font-size: 13px;
      background: #11111b; border-radius: 8px; padding: 12px;
    }
    .event { margin-bottom: 4px; white-space: pre-wrap; word-break: break-all; }
    .event-type { color: #f9e2af; }
    #input-row { display: flex; gap: 8px; margin-top: 12px; }
    #input-row input {
      flex: 1; padding: 8px; background: #313244; color: #cdd6f4;
      border: 1px solid #45475a; border-radius: 4px;
    }
    #input-row button {
      padding: 8px 16px; background: #cba6f7; color: #1e1e2e;
      border: none; border-radius: 4px; cursor: pointer;
    }
  </style>
</head>
<body>
  <h1>Eddie</h1>
  <div class=\"status\" id=\"status\">Connecting...</div>
  <div id=\"log\"></div>
  <div id=\"input-row\">
    <input id=\"msg\" placeholder=\"Send a message...\" />
    <button onclick=\"sendMessage()\">Send</button>
  </div>
  <script>
    const log = document.getElementById('log');
    const status = document.getElementById('status');
    let ws;

    function connect() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(proto + '//' + location.host + '/ws');
      ws.onopen = () => { status.textContent = 'Connected'; };
      ws.onclose = () => {
        status.textContent = 'Disconnected — reconnecting...';
        setTimeout(connect, 2000);
      };
      ws.onmessage = (e) => {
        try {
          const events = JSON.parse(e.data);
          if (Array.isArray(events)) {
            events.forEach(ev => appendEvent(ev));
          } else {
            appendEvent(events);
          }
        } catch (_) {
          appendRaw(e.data);
        }
      };
    }

    function appendEvent(ev) {
      const div = document.createElement('div');
      div.className = 'event';
      const type = ev.type || 'unknown';
      div.innerHTML = '<span class=\"event-type\">[' + type + ']</span> '
        + JSON.stringify(ev, null, 0);
      log.appendChild(div);
      log.scrollTop = log.scrollHeight;
    }

    function appendRaw(text) {
      const div = document.createElement('div');
      div.className = 'event';
      div.textContent = text;
      log.appendChild(div);
      log.scrollTop = log.scrollHeight;
    }

    function sendMessage() {
      const input = document.getElementById('msg');
      const text = input.value.trim();
      if (text && ws && ws.readyState === 1) {
        ws.send(JSON.stringify({user_input: text}));
        input.value = '';
      }
    }

    document.getElementById('msg').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') sendMessage();
    });

    connect();
  </script>
</body>
</html>"
}
