# Client-side markdown rendering over server-side

> **Superseded.** Phase 2 removed the inline HTML/JS frontend and its regex-based markdown renderer. Phase 4 built the Lustre SPA without markdown rendering — LLM response text is displayed as plain text with `white-space: pre-wrap`. A proper markdown library is deferred until it becomes a priority.

**The decision.** LLM response text was rendered as HTML by a minimal regex-based markdown parser in the frontend JavaScript, rather than being converted server-side in Gleam before sending over WebSocket.

## Why this and not the alternatives

Two approaches were considered:

1. **Server-side rendering in Gleam** — parse markdown to HTML in the agent or server module before sending the response text. Would require a Gleam markdown library or writing a parser.

2. **Client-side rendering in JavaScript (chosen at the time)** — the raw text was sent over WebSocket as-is, and the browser converted it to HTML before inserting into the DOM. The renderer was a ~15-line `renderMarkdown` function using regex replacements for common patterns.

## Why it was superseded

Phase 2 replaced the entire inline HTML/JS frontend with a minimal event-logging stub. Phase 4 built a Lustre SPA that renders LLM responses as plain text. The Lustre SPA could integrate a Gleam or JS markdown library in the future, but this is not yet implemented.

## What it cost (historical)

- The regex parser was fragile — no nested formatting, tables, or block quotes.
- No XSS protection beyond initial escaping.
- No syntax highlighting in code blocks.

## What made us reconsider

The Phase 2 removal of the inline HTML frontend made this trade-off moot. The Phase 4 Lustre SPA currently displays plain text — markdown rendering remains a future enhancement.
