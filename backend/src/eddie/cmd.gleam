/// Side-effect descriptors for the Elm-architecture widget system.
/// Each widget's update function returns a Cmd describing what should happen
/// next, without performing the effect itself.
///
/// The Initiator type lives in eddie_shared/initiator.
import gleam/dynamic.{type Dynamic}

import eddie_shared/initiator.{type Initiator, LLM, UI}

/// Elm-style command describing a side effect.
///
/// - `CmdNone` — no effect, no response to the caller
/// - `CmdToolResult` — respond to an LLM tool call with the given text
/// - `CmdEffect` — perform an async side effect; the runtime executes
///   `perform`, converts the result via `to_msg`, and feeds it back
///   into the widget's update function
pub type Cmd(msg) {
  CmdNone
  CmdToolResult(text: String)
  CmdEffect(perform: fn() -> Dynamic, to_msg: fn(Dynamic) -> msg)
}

/// Return the appropriate command for the given initiator:
/// LLM gets a tool result back, UI gets nothing.
pub fn for_initiator(
  initiator initiator: Initiator,
  text text: String,
) -> Cmd(msg) {
  case initiator {
    LLM -> CmdToolResult(text)
    UI -> CmdNone
  }
}
