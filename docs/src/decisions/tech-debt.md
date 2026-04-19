# Technical Debt

## Reversed-list index arithmetic in memory editing

`EditMemory` and `RemoveMemory` in `conversation_log.gleam` compute `mem_len - 1 - index` to map user-facing indices to the internal reversed list. This is correct but fragile — any change to the memory storage strategy requires updating the arithmetic in multiple places. If memory editing becomes more complex (reordering, bulk operations), consider switching to a data structure with direct index access or storing memories in display order and accepting the O(n) append cost.

## Duplicated Cmd loop in conversation_log typed API

`conversation_log.gleam` contains `execute_log_cmd_loop` which duplicates the logic of `widget.execute_cmd_loop`. This was introduced in Phase 3 because the `ConversationLog` typed API dispatches through the update function directly (bypassing `WidgetHandle`) and needs its own Cmd execution. The two loops handle the same three cases (`CmdNone`, `CmdToolResult`, `CmdEffect`) identically. If Cmd gains new variants, both loops must be updated. The fix would be to extract the Cmd loop into a shared function in `cmd.gleam` parameterised by the rebuild callback, but this was deferred because the current loop is trivial (6 lines of pattern matching).

## `tool_owners` map rebuilt on every mutation

`context.gleam` calls `rebuild_tool_owners` after every state change — every `handle_tool_call`, `add_user_message`, `add_response`, `handle_widget_event`, etc. This scans all widgets' `view_tools` and rebuilds the owner dict from scratch. The cost is proportional to the number of widgets times their tool count, which is small today (2-3 widgets, ~10 tools total) but would scale poorly with many widgets. If performance becomes an issue, the rebuild could be made lazy (only on `view_tools` or `handle_tool_call`) or incremental (track which widget changed and only rescan it).

## `changed_html` uses string comparison

`context.changed_html` renders each widget's HTML to a string via `element.to_string` and compares strings to detect changes. This is correct but wasteful — it serialises the entire element tree even when only a small part changed. A structural diff on the Lustre element tree would be more efficient but significantly more complex. This is acceptable for now since `changed_html` is called at most once per state mutation during a turn, not in a tight loop.

## Agent turn loop blocks the actor mailbox

The agent actor processes `RunTurn` synchronously — while a turn is in progress (which involves multiple HTTP round-trips to the LLM), all other messages (`GetState`, `Subscribe`, `Unsubscribe`, `DispatchEvent`) are queued. This means a subscriber registering during a turn won't receive updates until the turn completes, and `GetState` calls will block until the turn finishes. For single-user Milestone 1 this is acceptable because `Subscribe` is called at WebSocket init (before any turn), and `GetState` is not used in the hot path. With multi-agent support now in place (Phase 6), this becomes more pressing — child agents querying the parent or vice versa will block on a running turn. The turn could be offloaded to a spawned child process that sends state diffs back to the actor, keeping the mailbox responsive.

## No turn cancellation or timeout recovery

Once a turn starts, there is no way to cancel it from the browser or from the server. If the LLM hangs or the turn enters a long tool-call loop, the agent actor is blocked until the 25-iteration cap or the HTTP timeout (set by gleam_httpc defaults) kicks in. A cancellation mechanism would require the turn loop to check a cancellation flag between iterations, which is straightforward but was not implemented for Milestone 1.

## `json_to_dynamic` identity decoder workaround

`agent.gleam` uses `decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })` to create a decoder that passes through the raw `Dynamic` value from `json.parse`. This is a workaround for the absence of a built-in "parse JSON to Dynamic without decoding" function in `gleam_json`. It works correctly but is non-obvious. If `gleam_json` or `gleam_stdlib` adds a `json.parse_to_dynamic` or equivalent, this should be replaced.

## Structured output not integrated into the agent turn loop

`structured_output.extract` is a standalone function with its own `send_fn` parameter and retry loop, separate from the agent's turn loop. To use structured output during a turn, the caller would need to call `extract` outside the agent actor (or inject it as a tool effect), which means the extraction's intermediate state (retry messages, validation errors) is invisible to the conversation log and the subscriber notification system. Integrating structured output as a first-class turn step — where retries appear in the conversation log and trigger HTML updates — would require threading the Context through the extraction loop or running extraction as a sub-turn within the agent. This was deferred because the extraction use case (Phase 6 structured tools, structured agent responses) is not yet defined.

## `strip_dollar_schema` loses key ordering

`strip_dollar_schema` decodes the JSON schema to `Dict(String, Dynamic)`, filters out the `$schema` key, and re-encodes. Erlang maps (which back Gleam's `Dict`) do not preserve insertion order, so the output keys may appear in a different order than sextant produced them. This doesn't affect correctness (JSON object key order is not significant per spec) but makes the generated schema harder to diff or debug visually. If schema readability becomes important (e.g., for debugging failed extractions), consider building the schema without `$schema` in the first place.

## Duplicated `json_to_dynamic` identity decoder

`structured_output.gleam` contains its own `json_to_dynamic` function using `decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })`, identical to the one in `agent.gleam`. Both work around the absence of a built-in "parse JSON to Dynamic" in `gleam_json`. If a third module needs this, it should be extracted to a shared utility. See also the existing `json_to_dynamic` entry below.

## Spawned helper process for turn execution

The server spawns a `process.spawn` helper to call `agent.run_turn` because `AgentMessage` is opaque — the server cannot construct a `RunTurn` message directly and must go through the blocking public API. This means each user turn creates an extra BEAM process that exists only to bridge the call. The helper process is very lightweight (a single function call) but it introduces an indirection: the WebSocket handler sends no message to the agent directly for turns; instead, the spawned process calls `agent.run_turn`, and HTML updates flow back separately through the subscriber mechanism. An alternative would be to expose a public message constructor on the agent, but that would leak the internal protocol.

## Token usage widget found by string ID

`record_token_usage` in `agent.gleam` scans the children list with `list.map` looking for `widget.id(child) == "token_usage"`. If the widget's ID changes or is removed from the default widget tree, usage recording silently stops. A typed reference (similar to how ConversationLog is held typed in Context) would be safer but would further complicate Context's asymmetric widget treatment. See [trade-off card](./tradeoffs/10-token-usage-via-context-rebuild.md).

## Context reconstruction in record_token_usage

After sending usage data to the token_usage widget, `record_token_usage` creates an entirely new `Context` via `context.new(system_prompt, new_children, log)`, which triggers a full `rebuild_tool_owners` scan. This is an extra O(widgets × tools) rebuild per LLM response beyond the rebuilds already triggered by `add_response`. For the current widget count (5 widgets, ~12 tools) this is negligible, but it's architecturally wasteful. A `Context.update_child` or `Context.send_to_child` function would eliminate the reconstruction, but it would add mutation surface to an interface that is currently compose-and-dispatch only.

## AgentTree holds dead Subjects after child crashes

`AgentTree` stores child agent Subjects in a `Dict` but has no process monitoring. If a child actor crashes, its Subject remains in the dict. Any attempt to communicate with the dead child (via `agent.run_turn`, `agent.get_child`) will hang until the call timeout. There is no API to remove a child or detect a crashed one. Adding `process.monitor` for each child and handling `ProcessDown` messages would fix this, but requires `AgentTree` to become an actor itself (currently it's a pure data structure).

## File explorer reads entire files into memory

`do_read_file` in `file_explorer.gleam` calls `simplifile.read(path)` which loads the entire file as a single `String`. There is no size limit or streaming. Reading a large binary file or a multi-megabyte log will consume proportional memory in the agent process. A size check before reading, or a truncation strategy (read first N bytes), would be a minimal safety net.

## No file size or path traversal validation in file explorer

The file explorer's `open_directory` and `read_file` tools accept arbitrary paths from the LLM with no sandboxing or path traversal protection. The LLM can read any file the BEAM process has access to, including `..` paths, symlink targets, and sensitive configuration. For a single-user local agent this matches the trust model (the LLM acts on behalf of the user), but for any multi-user or exposed deployment, a path allowlist or chroot-like restriction would be essential.

## Inline HTML frontend exceeds natural size for a string literal

The `index_html()` function in `server.gleam` now contains ~200 lines of HTML/CSS and ~150 lines of JavaScript. This exceeds the threshold identified in [trade-off card 05](./tradeoffs/05-inline-html-over-lustre-spa.md) as a reconsideration trigger. Editing the frontend requires escaping quotes, there is no syntax highlighting, and no hot-reload. The frontend is functionally complete (activity bar, interactive widgets, markdown rendering, tool call display), making a migration to Lustre SPA or separate HTML files a reasonable next step if further frontend complexity is added. For now, the inline approach still works because the JS is straightforward DOM manipulation with no component state management.

## Minimal client-side markdown renderer

The `renderMarkdown()` function in `server.gleam` is a ~15-line regex-based parser handling fenced code blocks, inline code, bold, italic, headers, and lists. It does not handle nested formatting, block quotes, tables, horizontal rules, or escaped characters. For LLM output this is usually sufficient, but edge cases (nested bold inside code, multi-paragraph list items) will render incorrectly. Replacing with a proper library (e.g., marked.js) would fix these but adds an external dependency to a currently zero-dependency frontend.

## Token usage HTML change invisible to subscribers

In `agent.gleam`, `record_token_usage` updates the context before `old_ctx` is captured for the subsequent `notify_subscribers` call. This means the token usage widget's HTML change is included in both old and new context snapshots, so `changed_html` never detects it. Token usage updates only become visible when another widget's HTML changes in the same notification cycle (e.g., the conversation log). The fix would be to capture `old_ctx` before `record_token_usage`, but this changes the notification semantics for all widgets in that cycle.

## Inline JS event handlers in widget `view_html`

All interactive widgets generate inline `onclick`/`onkeydown`/`ondblclick` attributes with `sendWidgetEvent(...)` calls embedded as string literals. This works but has no compile-time safety — a typo in an event name or argument key is caught only at runtime. The file explorer uses an `escape_js` helper to prevent injection from file paths, but there is no systematic escaping strategy for other widgets. If widget interactivity grows more complex, a structured approach (e.g., data attributes with a single delegated event listener) would be more maintainable.
