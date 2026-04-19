# Technical Debt

## Reversed-list index arithmetic in memory editing

`EditMemory` and `RemoveMemory` in `conversation_log.gleam` compute `mem_len - 1 - index` to map user-facing indices to the internal reversed list. This is correct but fragile — any change to the memory storage strategy requires updating the arithmetic in multiple places. If memory editing becomes more complex (reordering, bulk operations), consider switching to a data structure with direct index access or storing memories in display order and accepting the O(n) append cost.

## Duplicated Cmd loop in conversation_log typed API

`conversation_log.gleam` contains `execute_log_cmd_loop` which duplicates the logic of `widget.execute_cmd_loop`. This was introduced in Phase 3 because the `ConversationLog` typed API dispatches through the update function directly (bypassing `WidgetHandle`) and needs its own Cmd execution. The two loops handle the same three cases (`CmdNone`, `CmdToolResult`, `CmdEffect`) identically. If Cmd gains new variants, both loops must be updated. The fix would be to extract the Cmd loop into a shared function in `cmd.gleam` parameterised by the rebuild callback, but this was deferred because the current loop is trivial (6 lines of pattern matching).

## `tool_owners` map rebuilt on every mutation

`context.gleam` calls `rebuild_tool_owners` after every state change — every `handle_tool_call`, `add_user_message`, `add_response`, `handle_widget_event`, etc. This scans all widgets' `view_tools` and rebuilds the owner dict from scratch. The cost is proportional to the number of widgets times their tool count, which is small today (2-3 widgets, ~10 tools total) but would scale poorly with many widgets. If performance becomes an issue, the rebuild could be made lazy (only on `view_tools` or `handle_tool_call`) or incremental (track which widget changed and only rescan it).

## No turn cancellation or timeout recovery

Once a turn starts, there is no way to cancel it from the browser or from the server. The agent is now reactive (Phase 3) — LLM calls run in spawned processes — so the actor itself is not blocked. However, there is no mechanism to tell a spawned LLM process to stop, and no way for the server to send a "cancel turn" command. If the LLM hangs, the spawned process waits indefinitely (there is no HTTP timeout enforcement beyond gleam_httpc defaults). A cancellation mechanism would require: (1) a `CancelTurn` message variant, (2) tracking the spawned process PID, (3) killing it and resetting agent state. This is now architecturally feasible (the agent can process messages during a turn) but was not implemented.

## `json_to_dynamic` identity decoder workaround

`agent.gleam` uses `decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })` to create a decoder that passes through the raw `Dynamic` value from `json.parse`. This is a workaround for the absence of a built-in "parse JSON to Dynamic without decoding" function in `gleam_json`. It works correctly but is non-obvious. If `gleam_json` or `gleam_stdlib` adds a `json.parse_to_dynamic` or equivalent, this should be replaced.

## Structured output not integrated into the agent turn loop

`structured_output.extract` is a standalone function with its own `send_fn` parameter and retry loop, separate from the agent's turn loop. To use structured output during a turn, the caller would need to call `extract` outside the agent actor (or inject it as a tool effect), which means the extraction's intermediate state (retry messages, validation errors) is invisible to the conversation log and the subscriber notification system. Integrating structured output as a first-class turn step — where retries appear in the conversation log and trigger HTML updates — would require threading the Context through the extraction loop or running extraction as a sub-turn within the agent. This was deferred because the extraction use case (Phase 6 structured tools, structured agent responses) is not yet defined.

## `strip_dollar_schema` loses key ordering

`strip_dollar_schema` decodes the JSON schema to `Dict(String, Dynamic)`, filters out the `$schema` key, and re-encodes. Erlang maps (which back Gleam's `Dict`) do not preserve insertion order, so the output keys may appear in a different order than sextant produced them. This doesn't affect correctness (JSON object key order is not significant per spec) but makes the generated schema harder to diff or debug visually. If schema readability becomes important (e.g., for debugging failed extractions), consider building the schema without `$schema` in the first place.

## Duplicated `json_to_dynamic` identity decoder

`structured_output.gleam` contains its own `json_to_dynamic` function using `decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })`, identical to the one in `agent.gleam`. Both work around the absence of a built-in "parse JSON to Dynamic" in `gleam_json`. If a third module needs this, it should be extracted to a shared utility. See also the existing `json_to_dynamic` entry below.

## No crash recovery for spawned LLM/effect processes

The agent spawns processes for LLM HTTP calls and tool effects via `process.spawn` (without link or monitor). If a spawned process crashes (e.g., an unexpected exception in `send_fn` or `perform`), the agent never receives a response. The turn hangs indefinitely — `llm_in_flight` remains `True` or the effect stays in `pending_effects`, and all subsequent user messages are queued forever. This is better than the pre-Phase-3 design (where a crash would take down the actor), but worse than proper process monitoring. Adding `process.monitor` for each spawned process and mapping `ProcessDown` to `LlmError` or `ToolEffectCrashed` would make the pattern robust.

## Token usage widget found by string ID

`record_token_usage` in `agent.gleam` scans the children list with `list.map` looking for `widget.id(child) == "token_usage"`. If the widget's ID changes or is removed from the default widget tree, usage recording silently stops. A typed reference (similar to how ConversationLog is held typed in Context) would be safer but would further complicate Context's asymmetric widget treatment. See [trade-off card](./tradeoffs/10-token-usage-via-context-rebuild.md).

## Context reconstruction in record_token_usage

After sending usage data to the token_usage widget, `record_token_usage` creates an entirely new `Context` via `context.new(system_prompt, new_children, log)`, which triggers a full `rebuild_tool_owners` scan. This is an extra O(widgets × tools) rebuild per LLM response beyond the rebuilds already triggered by `add_response`. For the current widget count (5 widgets, ~12 tools) this is negligible, but it's architecturally wasteful. A `Context.update_child` or `Context.send_to_child` function would eliminate the reconstruction, but it would add mutation surface to an interface that is currently compose-and-dispatch only.

## AgentTree holds dead Subjects after agent crashes

`AgentTree` stores all agent Subjects in a flat `Dict` but has no process monitoring. If an agent actor crashes, its Subject remains in the dict — and so do its children's entries and parent references. Any attempt to communicate with the dead agent (via `agent_tree.get_agent`) will return a dead Subject, and calls to it will hang until timeout. There is no API to remove an agent or detect a crashed one. With rose-tree nesting, a crashed parent leaves orphaned children that still reference a dead `parent_id`. Adding `process.monitor` for each agent and handling `ProcessDown` messages in the tree actor (with cascading cleanup of orphaned children) would fix this.

## File explorer reads entire files into memory

`do_read_file` in `file_explorer.gleam` calls `simplifile.read(path)` which loads the entire file as a single `String`. There is no size limit or streaming. Reading a large binary file or a multi-megabyte log will consume proportional memory in the agent process. A size check before reading, or a truncation strategy (read first N bytes), would be a minimal safety net.

## No file size or path traversal validation in file explorer

The file explorer's `open_directory` and `read_file` tools accept arbitrary paths from the LLM with no sandboxing or path traversal protection. The LLM can read any file the BEAM process has access to, including `..` paths, symlink targets, and sensitive configuration. For a single-user local agent this matches the trust model (the LLM acts on behalf of the user), but for any multi-user or exposed deployment, a path allowlist or chroot-like restriction would be essential.

## Token usage state change invisible to subscribers

In `agent.gleam`, `record_token_usage` updates the context before `old_ctx` is captured for the subsequent `notify_subscribers` call. This means the token usage widget's state change is included in both old and new context snapshots, so `changed_state` never detects it. Token usage updates only become visible when another widget's state changes in the same notification cycle (e.g., the conversation log). The fix would be to capture `old_ctx` before `record_token_usage`, but this changes the notification semantics for all widgets in that cycle.

## No agent deletion or cleanup

There is no way to delete an agent from the tree — once spawned, an agent lives until the BEAM VM shuts down. The tree has no `RemoveAgent` message, the protocol has no `DeleteAgent` command, and the frontend has no delete button. For long-running sessions where users create many throwaway root agents, this will accumulate memory. Adding a `RemoveAgent` message to the tree (with cascading child removal) and a corresponding protocol command would fix this.

## Mailbox broker has no persistence or size limits

The `MailboxBroker` stores all messages in-memory `Dict`s with no eviction, no size limits, and no persistence. A long-running session with chatty agents will accumulate messages indefinitely. All messages are lost on restart. If inbox sizes become a concern, adding a maximum inbox size with oldest-message eviction would be the minimal fix.

## Mailbox widget child_ids not updated at runtime

When a parent agent spawns a child via the `subagent_manager` tool, the mailbox widget's `child_ids` list is not updated — it was set at agent creation time and is immutable thereafter. This means the parent's `send_to_child` tool won't recognize newly spawned children until the mailbox widget is somehow reconstructed. The fix would be to add a `ChildSpawned` message to the mailbox widget's update function and have the agent_tree or subagent_manager notify it when a child is added.

## Agent status not tracked at runtime

`AgentTree` stores an `AgentStatus` per agent but never updates it — all agents show `AgentIdle` regardless of whether they're mid-turn. The `update_status` API exists and is called nowhere. Wiring `TurnStarted`/`TurnCompleted` events from the agent to the tree via `update_status` would make the status live, but requires the agent to know its tree's Subject (currently not passed to the agent).

## UUID generation uses hand-rolled Erlang FFI

`eddie_ffi.erl` contains a hand-rolled UUID v4 generator using `crypto:strong_rand_bytes`. This works but doesn't use a standard UUID library. If Erlang's `uuid` module or a hex.pm UUID package is available, replacing the FFI would be cleaner. The current implementation correctly sets version and variant bits but has no tests.

