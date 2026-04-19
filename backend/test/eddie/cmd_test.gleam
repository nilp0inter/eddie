import eddie/cmd
import eddie_shared/initiator.{LLM, UI}
import gleeunit/should

pub fn cmd_none_test() {
  let command: cmd.Cmd(String) = cmd.CmdNone
  let assert cmd.CmdNone = command
}

pub fn cmd_tool_result_test() {
  let command = cmd.CmdToolResult("hello")
  let assert cmd.CmdToolResult(text) = command
  text |> should.equal("hello")
}

pub fn for_initiator_llm_returns_tool_result_test() {
  let result: cmd.Cmd(String) =
    cmd.for_initiator(initiator: LLM, text: "done")
  let assert cmd.CmdToolResult(text) = result
  text |> should.equal("done")
}

pub fn for_initiator_ui_returns_none_test() {
  let result: cmd.Cmd(String) =
    cmd.for_initiator(initiator: UI, text: "done")
  let assert cmd.CmdNone = result
}
