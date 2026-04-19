# Client-side markdown rendering over server-side

> **Superseded.** Phase 2 replaced the inline HTML/JS frontend with a minimal event-logging stub. The regex-based markdown renderer no longer exists. Markdown rendering will be revisited when the Lustre SPA frontend is built in Phase 4.

**The decision.** LLM response text was rendered as HTML by a minimal regex-based markdown parser in the frontend JavaScript, rather than being converted server-side in Gleam before sending over WebSocket.

## Why this and not the alternatives

Two approaches were considered:

1. **Server-side rendering in Gleam** — parse markdown to HTML in the agent or server module before sending the response text. Would require a Gleam markdown library or writing a parser.

2. **Client-side rendering in JavaScript (chosen at the time)** — the raw text was sent over WebSocket as-is, and the browser converted it to HTML before inserting into the DOM. The renderer was a ~15-line `renderMarkdown` function using regex replacements for common patterns.

## Why it was superseded

Phase 2 replaced the entire inline HTML/JS frontend with a minimal event-logging stub that displays raw JSON events. The regex-based markdown renderer was removed along with the rest of the frontend JavaScript. When the Lustre SPA frontend is built (Phase 4), markdown rendering will be implemented in client-side Gleam code, likely using a proper library that compiles to JavaScript.

## What it cost (historical)

- The regex parser was fragile — no nested formatting, tables, or block quotes.
- No XSS protection beyond initial escaping.
- No syntax highlighting in code blocks.

## What made us reconsider

The Phase 2 removal of the inline HTML frontend made this trade-off moot. The rendering concern remains for Phase 4 but will be addressed with different technology (Lustre SPA with a Gleam markdown library).
