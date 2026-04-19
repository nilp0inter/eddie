# Token usage recording via Context reconstruction

**The decision.** The agent records token usage by scanning the children list for the `"token_usage"` widget by string ID, sending it a message via `widget.send`, then reconstructing a new `Context` from the accessors (`context.system_prompt`, `context.children`, `context.log`).

## Why this and not the alternatives

Three alternatives were considered:

1. **Add a `send_to_child` function on Context** — would require Context to support targeted child mutations, which adds complexity to an otherwise read-compose-dispatch interface. Context deliberately rebuilds `tool_owners` after every mutation; adding a new mutation path means another rebuild trigger and another place to get the ordering wrong.

2. **Store token_usage as a typed widget (like ConversationLog)** — gives direct access without string ID lookup, but creates a second special-cased widget in Context. The ConversationLog's typed treatment is already documented as a trade-off with ongoing costs (duplicated Cmd loop, asymmetric code). Adding a second typed widget doubles the asymmetry.

3. **Have the LLM bridge return usage separately and let the caller handle it** — this is what we do (`parse_response` returns `#(Message, Option(TokenUsage))`), but the "caller" is the agent actor, and it still needs to get the data into a widget somehow.

The chosen approach (string ID lookup + Context reconstruction) is the simplest that works. It requires no new API on Context and reuses the existing `widget.send` mechanism.

## What it costs

- **String-typed coupling** — the agent assumes a child widget with ID `"token_usage"` exists. If the ID changes or the widget is removed, usage recording silently stops.
- **Context reconstruction** — `record_token_usage` calls `context.new(system_prompt, children, log)` which triggers a full `rebuild_tool_owners`. This is an extra O(widgets × tools) scan per LLM response, on top of the rebuilds already triggered by `add_response`.
- **Widget scan** — `list.map` over all children to find the one with the right ID is O(n) per response. With 3 children this is negligible but would scale poorly.

## What would make us reconsider

- A third widget needs to receive data from the agent turn loop (not just token_usage). At that point, a general `Context.send_to_child(id, msg)` API would pay for itself.
- The children list grows large enough that the linear scan + full rebuild becomes measurable.
- The string ID coupling causes a real bug (widget renamed, ID typo, etc.) — a typed reference or a widget registry would prevent this class of error.
