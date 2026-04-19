# Technical Debt

## Placeholder `view_html` in Phase 2 widgets

Both `system_prompt.gleam` and `conversation_log.gleam` have stub `view_html` implementations — a textarea with buttons for SystemPrompt, and a text summary for ConversationLog. The Calipso reference has rich interactive HTML (collapsible task blocks, memory editing inline, tool call grouping). These stubs will be replaced in Phase 4 when the Lustre SPA and Mist server are wired up, since the HTML is meaningless until there's a browser to render it in.

## Reversed-list index arithmetic in memory editing

`EditMemory` and `RemoveMemory` in `conversation_log.gleam` compute `mem_len - 1 - index` to map user-facing indices to the internal reversed list. This is correct but fragile — any change to the memory storage strategy requires updating the arithmetic in multiple places. If memory editing becomes more complex (reordering, bulk operations), consider switching to a data structure with direct index access or storing memories in display order and accepting the O(n) append cost.

## Duplicated Cmd loop in conversation_log typed API

`conversation_log.gleam` contains `execute_log_cmd_loop` which duplicates the logic of `widget.execute_cmd_loop`. This was introduced in Phase 3 because the `ConversationLog` typed API dispatches through the update function directly (bypassing `WidgetHandle`) and needs its own Cmd execution. The two loops handle the same three cases (`CmdNone`, `CmdToolResult`, `CmdEffect`) identically. If Cmd gains new variants, both loops must be updated. The fix would be to extract the Cmd loop into a shared function in `cmd.gleam` parameterised by the rebuild callback, but this was deferred because the current loop is trivial (6 lines of pattern matching).

## `tool_owners` map rebuilt on every mutation

`context.gleam` calls `rebuild_tool_owners` after every state change — every `handle_tool_call`, `add_user_message`, `add_response`, `handle_widget_event`, etc. This scans all widgets' `view_tools` and rebuilds the owner dict from scratch. The cost is proportional to the number of widgets times their tool count, which is small today (2-3 widgets, ~10 tools total) but would scale poorly with many widgets. If performance becomes an issue, the rebuild could be made lazy (only on `view_tools` or `handle_tool_call`) or incremental (track which widget changed and only rescan it).

## `changed_html` uses string comparison

`context.changed_html` renders each widget's HTML to a string via `element.to_string` and compares strings to detect changes. This is correct but wasteful — it serialises the entire element tree even when only a small part changed. A structural diff on the Lustre element tree would be more efficient but significantly more complex. This is acceptable for now since `changed_html` is called at most once per agent turn, not in a hot loop.
