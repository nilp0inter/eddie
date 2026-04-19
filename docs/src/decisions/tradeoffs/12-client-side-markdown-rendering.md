# Client-side markdown rendering over server-side

**The decision.** LLM response text is rendered as HTML by a minimal regex-based markdown parser in the frontend JavaScript, rather than being converted server-side in Gleam before sending over WebSocket.

## Why this and not the alternatives

Two approaches were considered:

1. **Server-side rendering in Gleam** — parse markdown to HTML in the agent or server module before sending the response text. Would require a Gleam markdown library or writing a parser. The rendered HTML would be sent as part of the `turn_end` JSON payload or as an OOB widget swap.

2. **Client-side rendering in JavaScript (chosen)** — the raw text is sent over WebSocket as-is, and the browser converts it to HTML before inserting into the DOM. The renderer is a ~15-line `renderMarkdown` function using regex replacements for common patterns.

Client-side was chosen because:
- No Gleam markdown library is needed. The existing codebase has zero frontend-related Gleam dependencies beyond Lustre (which produces server-side HTML for widget views, not for chat messages).
- Chat messages arrive as plain strings via the `turn_end` JSON payload. Adding markdown rendering at the server would mean either changing the payload format (breaking the clean text/error split) or adding a new widget that tracks chat messages (duplicating the conversation log's responsibility).
- The regex approach handles the patterns that LLMs actually produce (code blocks, headers, bold, lists) without a full parser. Edge cases in nested formatting are rare in LLM output.

## What it costs

- **The regex parser is fragile.** Nested formatting (`**bold *italic***`), escaped characters, multi-paragraph list items, tables, and block quotes are not handled. These are uncommon in LLM output but not impossible.
- **No XSS protection beyond initial escaping.** The renderer escapes `<`, `>`, `&` before applying regex transformations, then inserts via `innerHTML`. This is safe for LLM-generated text but would be a vulnerability if untrusted user input were ever rendered through the same path.
- **No syntax highlighting in code blocks.** Fenced code blocks render as plain `<pre><code>` without language-specific colouring. Adding highlight.js or similar would require an external dependency.

## What would make us reconsider

- **Users report rendering bugs in LLM output** (broken tables, corrupted nested formatting) frequently enough that the regex approach becomes a maintenance burden. At that point, embedding a proper library (marked.js, ~25KB) or switching to server-side rendering would be justified.
- **A move to Lustre SPA** (see [trade-off card 05](./05-inline-html-over-lustre-spa.md)) would naturally relocate markdown rendering to the client-side Gleam code, using a Gleam markdown library that compiles to JavaScript.
