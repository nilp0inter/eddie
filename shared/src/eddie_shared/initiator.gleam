/// Who triggered a widget message — determines whether a tool result
/// should be sent back (LLM expects a response) or silently applied
/// (UI does not).
pub type Initiator {
  LLM
  UI
}
