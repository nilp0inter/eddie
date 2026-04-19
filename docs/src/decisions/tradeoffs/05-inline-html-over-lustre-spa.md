# Inline HTML + plain JS over Lustre SPA

**The decision.** The Phase 4 browser frontend is a self-contained HTML page with embedded CSS and ~40 lines of vanilla JavaScript, served as an inline string from `server.gleam`, rather than a Lustre SPA compiled to JavaScript as a separate compilation unit.

## Why this and not the alternatives

Three approaches were considered:

1. **Lustre SPA (JS target, separate project)** — the original plan. A full Gleam-to-JS frontend with WebSocket state management, component rendering, and client-side routing. This requires a separate `gleam.toml` targeting JavaScript, a build pipeline to bundle the output, and a way to serve the compiled JS from the Erlang server. It also means maintaining two compilation targets in a project that currently only targets Erlang.

2. **htmx with server-rendered fragments** — Calipso's approach. Depends on the htmx library for out-of-band DOM swapping over WebSocket. Adds an external JS dependency and couples the wire protocol to htmx's `hx-swap-oob` attribute convention.

3. **Inline HTML + plain JS (chosen)** — the page is a Gleam string constant in `server.gleam`. The JavaScript handles WebSocket connection, JSON message parsing, and manual DOM element replacement keyed by `data-swap-oob` IDs. No build step, no external JS dependencies, no second compilation target.

The inline approach was chosen because:
- Eddie's widgets already produce server-side HTML via `view_html` (Lustre elements rendered to strings). The browser just needs to display and swap these fragments — it doesn't need a client-side virtual DOM.
- A Lustre SPA would duplicate rendering logic: widgets would render HTML on the server *and* the client would need to understand widget state to render its own UI.
- The Milestone 1 goal is an end-to-end working chat, not a rich interactive frontend. The inline approach gets there with zero additional build complexity.
- The ~40 lines of JavaScript are trivial to maintain and have no dependency surface.

## What it costs

- **No client-side interactivity beyond what the server pushes.** Every widget interaction (task toggle, memory edit) must round-trip through the WebSocket to the agent and back. There is no optimistic UI or client-side state.
- **The HTML page is a string literal in Gleam source.** It's awkward to edit (no syntax highlighting, escaping issues with quotes), and there's no hot-reload during frontend development.
- **No type safety in the frontend.** The JavaScript is hand-written with no compile-time guarantees — typos in element IDs or message formats are caught only at runtime.
- **Widget HTML updates replace `innerHTML` wholesale** rather than diffing. For simple widgets this is fine; for widgets with form inputs or scroll position, the swap would destroy local state.

## What would make us reconsider

- **Widgets need client-side state** (e.g., a code editor widget, drag-and-drop task reordering, or inline memory editing with undo). At that point, the round-trip latency for every interaction becomes unacceptable and a client-side framework is justified.
- **The inline HTML string exceeds ~200 lines** or needs conditional rendering logic. At that point, maintaining it as a Gleam string is more painful than setting up a proper frontend build.
- **Multi-agent support requires complex client-side routing** (agent selection, per-agent dashboards, spawning UI). Phase 6 added `AgentTree` with hierarchical agents, but the frontend currently only connects to a single agent. Exposing multi-agent navigation in the UI would be a natural trigger for a Lustre SPA.
