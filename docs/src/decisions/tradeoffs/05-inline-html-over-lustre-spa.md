# Inline HTML + plain JS over Lustre SPA

> **Superseded.** Phase 2 replaced `view_html` with `view_state` returning `List(ServerEvent)`, removed the `lustre` dependency from the backend, and replaced the inline HTML/JS frontend with a minimal event-logging stub. The backend no longer produces HTML. A Lustre SPA frontend is planned for Phase 4.

**The decision.** The browser frontend was a self-contained HTML page with embedded CSS and ~150 lines of vanilla JavaScript, served as an inline string from `frontend.gleam`, rather than a Lustre SPA compiled to JavaScript as a separate compilation unit.

## Why this and not the alternatives

Three approaches were considered:

1. **Lustre SPA (JS target, separate project)** — the original plan. A full Gleam-to-JS frontend with WebSocket state management, component rendering, and client-side routing. This requires a separate `gleam.toml` targeting JavaScript, a build pipeline to bundle the output, and a way to serve the compiled JS from the Erlang server. It also means maintaining two compilation targets in a project that currently only targets Erlang.

2. **htmx with server-rendered fragments** — Calipso's approach. Depends on the htmx library for out-of-band DOM swapping over WebSocket. Adds an external JS dependency and couples the wire protocol to htmx's `hx-swap-oob` attribute convention.

3. **Inline HTML + plain JS (chosen at the time)** — the page was a Gleam string constant in `frontend.gleam` (served by `server.gleam`). The JavaScript handled WebSocket connection, JSON message parsing, manual DOM element replacement, activity bar panel toggling, markdown rendering, and tool call display. No build step, no external JS dependencies, no second compilation target.

## Why it was superseded

The inline approach was replaced in Phase 2 because:
- Widgets now produce `List(ServerEvent)` domain events instead of HTML — there is no server-side HTML to swap.
- The `lustre` dependency was removed from the backend entirely.
- The frontend was replaced with a minimal event-logging stub that displays raw JSON events, serving as a placeholder until the Lustre SPA is built in Phase 4.
- The costs identified below (no client-side state, innerHTML clobbering, string literal awkwardness) are no longer relevant since the inline HTML approach is gone.

## What it cost (historical)

- No client-side interactivity beyond what the server pushed.
- The HTML page was a string literal in Gleam source — awkward to edit.
- No type safety in the frontend JavaScript.
- Widget HTML updates replaced `innerHTML` wholesale, destroying local state.
- The client-side markdown renderer was minimal (~15 lines of regex).

## What made us reconsider

The Phase 2 architectural change (widgets producing domain events instead of HTML) made the inline HTML approach structurally incompatible. The backend no longer generates HTML, so the frontend must render its own UI from domain events — exactly the use case for a Lustre SPA.
