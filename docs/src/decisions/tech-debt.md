# Technical Debt

## Placeholder `view_html` in Phase 2 widgets

Both `system_prompt.gleam` and `conversation_log.gleam` have stub `view_html` implementations — a textarea with buttons for SystemPrompt, and a text summary for ConversationLog. The Calipso reference has rich interactive HTML (collapsible task blocks, memory editing inline, tool call grouping). These stubs are now rendered in the browser sidebar via the Phase 4 server, but they remain minimal. Rich widget HTML should be implemented once the end-to-end loop is stable and the widget interaction patterns are settled.

## Reversed-list index arithmetic in memory editing

`EditMemory` and `RemoveMemory` in `conversation_log.gleam` compute `mem_len - 1 - index` to map user-facing indices to the internal reversed list. This is correct but fragile — any change to the memory storage strategy requires updating the arithmetic in multiple places. If memory editing becomes more complex (reordering, bulk operations), consider switching to a data structure with direct index access or storing memories in display order and accepting the O(n) append cost.

## Duplicated Cmd loop in conversation_log typed API

`conversation_log.gleam` contains `execute_log_cmd_loop` which duplicates the logic of `widget.execute_cmd_loop`. This was introduced in Phase 3 because the `ConversationLog` typed API dispatches through the update function directly (bypassing `WidgetHandle`) and needs its own Cmd execution. The two loops handle the same three cases (`CmdNone`, `CmdToolResult`, `CmdEffect`) identically. If Cmd gains new variants, both loops must be updated. The fix would be to extract the Cmd loop into a shared function in `cmd.gleam` parameterised by the rebuild callback, but this was deferred because the current loop is trivial (6 lines of pattern matching).

## `tool_owners` map rebuilt on every mutation

`context.gleam` calls `rebuild_tool_owners` after every state change — every `handle_tool_call`, `add_user_message`, `add_response`, `handle_widget_event`, etc. This scans all widgets' `view_tools` and rebuilds the owner dict from scratch. The cost is proportional to the number of widgets times their tool count, which is small today (2-3 widgets, ~10 tools total) but would scale poorly with many widgets. If performance becomes an issue, the rebuild could be made lazy (only on `view_tools` or `handle_tool_call`) or incremental (track which widget changed and only rescan it).

## `changed_html` uses string comparison

`context.changed_html` renders each widget's HTML to a string via `element.to_string` and compares strings to detect changes. This is correct but wasteful — it serialises the entire element tree even when only a small part changed. A structural diff on the Lustre element tree would be more efficient but significantly more complex. This is acceptable for now since `changed_html` is called at most once per state mutation during a turn, not in a tight loop.

## Agent turn loop blocks the actor mailbox

The agent actor processes `RunTurn` synchronously — while a turn is in progress (which involves multiple HTTP round-trips to the LLM), all other messages (`GetState`, `Subscribe`, `Unsubscribe`, `DispatchEvent`) are queued. This means a subscriber registering during a turn won't receive updates until the turn completes, and `GetState` calls will block until the turn finishes. For single-user Milestone 1 this is acceptable because `Subscribe` is called at WebSocket init (before any turn), and `GetState` is not used in the hot path. For multi-agent Phase 6, the turn could be offloaded to a spawned child process that sends state diffs back to the actor, keeping the mailbox responsive.

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
