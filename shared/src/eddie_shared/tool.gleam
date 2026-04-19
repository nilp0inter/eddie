/// Tool-related types for cross-boundary use.
///
/// The ToolDefinition type itself stays in the backend (eddie/tool)
/// since the frontend never constructs tool definitions. This module
/// is reserved for any tool-related types that need to cross the
/// WebSocket boundary in the future.
pub fn placeholder() -> Nil {
  Nil
}
