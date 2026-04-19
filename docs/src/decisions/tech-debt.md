# Technical Debt

## Placeholder `view_html` in Phase 2 widgets

Both `system_prompt.gleam` and `conversation_log.gleam` have stub `view_html` implementations — a textarea with buttons for SystemPrompt, and a text summary for ConversationLog. The Calipso reference has rich interactive HTML (collapsible task blocks, memory editing inline, tool call grouping). These stubs will be replaced in Phase 4 when the Lustre SPA and Mist server are wired up, since the HTML is meaningless until there's a browser to render it in.

## Reversed-list index arithmetic in memory editing

`EditMemory` and `RemoveMemory` in `conversation_log.gleam` compute `mem_len - 1 - index` to map user-facing indices to the internal reversed list. This is correct but fragile — any change to the memory storage strategy requires updating the arithmetic in multiple places. If memory editing becomes more complex (reordering, bulk operations), consider switching to a data structure with direct index access or storing memories in display order and accepting the O(n) append cost.
