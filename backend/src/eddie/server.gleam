/// HTTP server and WebSocket handler — serves the Eddie web UI.
///
/// Uses mist for HTTP serving and WebSocket connections.
/// Each WebSocket connection subscribes to the agent for state updates.
/// The agent broadcasts all events (including TurnStarted/TurnCompleted)
/// through the subscriber mechanism.
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}

import eddie/agent.{type AgentMessage}
import eddie/frontend
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
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(frontend.index_html())),
  )
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
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
  WsState(agent: Subject(AgentMessage), update_subject: Subject(String))
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
  // Create a subject for receiving state updates from the agent
  let update_subject = process.new_subject()

  // Build a selector that maps updates to WsCustomMessage
  let selector =
    process.new_selector()
    |> process.select_map(update_subject, fn(payload) { StateUpdate(payload:) })

  // Subscribe to agent updates
  agent.subscribe(subject: agent_subject, subscriber: update_subject)

  // Send initial state events so panels are populated immediately
  let initial_state =
    agent.get_current_state(subject: agent_subject, timeout: 5000)
  let _sent = mist.send_text_frame(conn, initial_state)

  let state = WsState(agent: agent_subject, update_subject: update_subject)
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
  let user_input_decoder = decode.at(["user_input"], decode.string)
  let widget_event_decoder = {
    use event_name <- decode.field("event_name", decode.string)
    use args_json <- decode.field("args_json", decode.string)
    decode.success(#(event_name, args_json))
  }

  case json.parse(text, user_input_decoder) {
    Ok(user_text) -> {
      // Fire-and-forget — agent broadcasts TurnStarted/TurnCompleted
      // through the subscriber mechanism
      agent.send_message(subject: state.agent, text: user_text)
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
