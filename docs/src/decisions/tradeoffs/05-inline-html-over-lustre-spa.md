# Inline HTML + plain JS over Lustre SPA

**The decision.** The browser frontend is a self-contained HTML page with embedded CSS and ~150 lines of vanilla JavaScript, served as an inline string from `server.gleam`, rather than a Lustre SPA compiled to JavaScript as a separate compilation unit.

## Why this and not the alternatives

Three approaches were considered:

1. **Lustre SPA (JS target, separate project)** — the original plan. A full Gleam-to-JS frontend with WebSocket state management, component rendering, and client-side routing. This requires a separate `gleam.toml` targeting JavaScript, a build pipeline to bundle the output, and a way to serve the compiled JS from the Erlang server. It also means maintaining two compilation targets in a project that currently only targets Erlang.

2. **htmx with server-rendered fragments** — Calipso's approach. Depends on the htmx library for out-of-band DOM swapping over WebSocket. Adds an external JS dependency and couples the wire protocol to htmx's `hx-swap-oob` attribute convention.

3. **Inline HTML + plain JS (chosen)** — the page is a Gleam string constant in `server.gleam`. The JavaScript handles WebSocket connection, JSON message parsing, manual DOM element replacement keyed by `data-swap-oob` IDs, activity bar panel toggling, markdown rendering, and tool call display. No build step, no external JS dependencies, no second compilation target.

The inline approach was chosen because:
- Eddie's widgets already produce server-side HTML via `view_html` (Lustre elements rendered to strings). The browser just needs to display and swap these fragments — it doesn't need a client-side virtual DOM.
- A Lustre SPA would duplicate rendering logic: widgets would render HTML on the server *and* the client would need to understand widget state to render its own UI.
- The inline approach gets to a fully functional frontend with zero additional build complexity.
- All widget interactivity flows through `sendWidgetEvent` → WebSocket → agent → widget `from_ui`, which is architecturally clean even though it round-trips every interaction.

## What it costs

- **No client-side interactivity beyond what the server pushes.** Every widget interaction (task toggle, memory edit, file open) must round-trip through the WebSocket to the agent and back. There is no optimistic UI or client-side state.
- **The HTML page is a string literal in Gleam source.** It's awkward to edit (no syntax highlighting, escaping issues with quotes), and there's no hot-reload during frontend development. The inline page now exceeds ~200 lines of HTML/CSS and ~150 lines of JS, which is past the original threshold for reconsidering this approach (see [tech debt](../tech-debt.md)).
- **No type safety in the frontend.** The JavaScript is hand-written with no compile-time guarantees — typos in element IDs or message formats are caught only at runtime. Widget `view_html` functions embed inline JS handlers as string attributes, adding another layer of untyped glue.
- **Widget HTML updates replace `innerHTML` wholesale** rather than diffing. For simple widgets this is fine; for widgets with form inputs or scroll position, the swap destroys local state. Textarea content in the system prompt widget, for example, resets on every server-pushed update.
- **The client-side markdown renderer is minimal.** It handles common patterns (fenced code, bold, italic, headers, lists) but not nested formatting, tables, or escaped characters.

## What would make us reconsider

- **Widgets need client-side state** (e.g., a code editor widget, drag-and-drop task reordering, or inline memory editing with undo). At that point, the round-trip latency for every interaction becomes unacceptable and a client-side framework is justified.
- **Multi-agent support requires complex client-side routing** (agent selection, per-agent dashboards, spawning UI). Phase 6 added `AgentTree` with hierarchical agents, but the frontend currently only connects to a single agent. Exposing multi-agent navigation in the UI would be a natural trigger for a Lustre SPA.
- **The innerHTML replacement problem becomes blocking.** If widgets with persistent local state (form inputs, scroll position, selection) are frequently clobbered by server pushes, the lack of client-side diffing becomes a usability issue rather than a theoretical cost.
