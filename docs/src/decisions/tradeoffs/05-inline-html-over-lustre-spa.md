# Inline HTML + plain JS over Lustre SPA

> **Superseded.** Phase 2 replaced `view_html` with `view_state` returning `List(ServerEvent)` and removed the `lustre` dependency from the backend. Phase 4 replaced the event-logging stub with a full Lustre SPA frontend.

**The decision.** The browser frontend was a self-contained HTML page with embedded CSS and ~150 lines of vanilla JavaScript, served as an inline string from `frontend.gleam`, rather than a Lustre SPA compiled to JavaScript as a separate compilation unit.

## Why this and not the alternatives

Three approaches were considered:

1. **Lustre SPA (JS target, separate project)** — the original plan. A full Gleam-to-JS frontend with WebSocket state management, component rendering, and client-side routing. This requires a separate `gleam.toml` targeting JavaScript, a build pipeline to bundle the output, and a way to serve the compiled JS from the Erlang server. It also means maintaining two compilation targets in a project that currently only targets Erlang.

2. **htmx with server-rendered fragments** — Calipso's approach. Depends on the htmx library for out-of-band DOM swapping over WebSocket. Adds an external JS dependency and couples the wire protocol to htmx's `hx-swap-oob` attribute convention.

3. **Inline HTML + plain JS (chosen at the time)** — the page was a Gleam string constant in `frontend.gleam` (served by `server.gleam`). The JavaScript handled WebSocket connection, JSON message parsing, manual DOM element replacement, activity bar panel toggling, markdown rendering, and tool call display. No build step, no external JS dependencies, no second compilation target.

## Why it was superseded

Phase 2 removed HTML generation from the backend — widgets produce `List(ServerEvent)` domain events. Phase 4 built the Lustre SPA:

- Single-module Lustre app (`eddie_frontend.gleam`) compiled to JS and bundled with esbuild
- Uses `lustre_websocket` for WebSocket connection with auto-reconnect
- Decodes `ServerEvent` arrays via shared decoders, encodes `ClientCommand` to send
- Chat UI with user/assistant messages, collapsible tool results, tool call badges, thinking indicator
- Sidebar panels: Goal, Tasks, Files, Token Usage
- Backend `server.gleam` serves an HTML shell + bundled `app.js`, parses `ClientCommand` JSON
- `frontend.gleam` deleted from the backend

## What it cost (historical)

- No client-side interactivity beyond what the server pushed.
- The HTML page was a string literal in Gleam source — awkward to edit.
- No type safety in the frontend JavaScript.
- Widget HTML updates replaced `innerHTML` wholesale, destroying local state.
- The client-side markdown renderer was minimal (~15 lines of regex).

## What made us reconsider

The Phase 2 architectural change (widgets producing domain events instead of HTML) made the inline HTML approach structurally incompatible. The backend no longer generates HTML, so the frontend must render its own UI from domain events — exactly the use case for a Lustre SPA.
