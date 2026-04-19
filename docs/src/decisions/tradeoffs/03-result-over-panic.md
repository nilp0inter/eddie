# Result types instead of panics for tool.new and widget.send

**The decision.** `tool.new` returns `Result(ToolDefinition, ToolError)` and `widget.send` returns `Result(WidgetHandle, SendError)`, instead of using `let assert` to panic on invalid input.

## Why this and not the alternatives

The original plan had both functions using `let assert`:
- `tool.new` would `let assert Ok(dynamic_value) = json.parse(...)` — panicking if JSON re-parsing fails
- `widget.send` would `let assert CmdNone = cmd` — panicking if the widget's update produces a command

Glinter flagged both as `assert_ok_pattern` warnings: "let assert crashes on mismatch: return Result and let the caller handle the error." This aligns with Gleam's convention that libraries must not panic.

The alternative of keeping `let assert` was rejected because:
- `tool.new` is called with user-constructed JSON — while unlikely to fail, the round-trip through `json.to_string` then `json.parse` could theoretically produce a decode error
- `widget.send` is called by Context with messages that *should* produce `CmdNone`, but a widget bug could violate this. A `Result` lets Context handle the error gracefully instead of crashing the agent process

## What it costs

- Callers of `tool.new` must handle `Result` (typically `let assert Ok(td) = tool.new(...)` in application code, which is acceptable — the panic moves to the call site where context is clearer).
- `widget.send` callers must handle `SendError`, adding one `case` or `let assert` per call site.

## What would make us reconsider

If these functions are called in hot paths where the `Result` wrapping has measurable overhead, or if every single call site uses `let assert Ok(...)` anyway, we could revert to panicking versions. But for now, the explicit error handling is worth the minor ergonomic cost.
