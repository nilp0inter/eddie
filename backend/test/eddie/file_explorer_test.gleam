import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should

import eddie_shared/message
import eddie/widget

import eddie/widgets/file_explorer

// ============================================================================
// Factory tests
// ============================================================================

pub fn create_empty_test() {
  let handle = file_explorer.create()
  widget.id(handle)
  |> should.equal("file_explorer")
}

pub fn empty_view_messages_test() {
  let handle = file_explorer.create()
  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(handle)
  string.contains(text, "No directory or file open.")
  |> should.be_true
}

// ============================================================================
// LLM tool dispatch tests — open_directory triggers CmdEffect
// ============================================================================

// open_directory triggers a CmdEffect that performs real IO.
// We test it end-to-end by opening a known directory (the project root).
pub fn open_directory_via_llm_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("."))])
  let #(updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "open_directory", args: args)
  // CmdEffect runs do_open_directory(".") which should succeed
  result
  |> should.be_ok

  // Messages should now contain the directory listing
  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  string.contains(text, "Contents of `.`")
  |> should.be_true
}

pub fn open_directory_default_path_test() {
  let handle = file_explorer.create()
  // No path arg → defaults to "."
  let args = make_args([])
  let #(updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "open_directory", args: args)
  result
  |> should.be_ok

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  string.contains(text, "Contents of `.`")
  |> should.be_true
}

pub fn open_nonexistent_directory_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("/nonexistent_path_12345"))])
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "open_directory", args: args)
  let assert Ok(text) = result
  string.contains(text, "Not a directory")
  |> should.be_true
}

// ============================================================================
// read_file tests
// ============================================================================

pub fn read_file_via_llm_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("gleam.toml"))])
  let #(updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "read_file", args: args)
  result
  |> should.equal(Ok("Opened: gleam.toml"))

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  string.contains(text, "**Open file:** `gleam.toml`")
  |> should.be_true
  // Should contain actual file content
  string.contains(text, "name = \"eddie\"")
  |> should.be_true
}

pub fn read_nonexistent_file_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("nonexistent_file.txt"))])
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "read_file", args: args)
  let assert Ok(text) = result
  string.contains(text, "File not found")
  |> should.be_true
}

pub fn read_file_missing_path_test() {
  let handle = file_explorer.create()
  let args = make_args([])
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "read_file", args: args)
  result
  |> should.equal(Error("read_file: missing 'path' field"))
}

// ============================================================================
// Close tests
// ============================================================================

pub fn close_directory_via_llm_test() {
  let handle = file_explorer.create()
  // First open a directory
  let args = make_args([#("path", json.string("."))])
  let #(updated, _) =
    widget.dispatch_llm(handle: handle, tool_name: "open_directory", args: args)
  // Now close it
  let close_args = make_args([#("path", json.string("."))])
  let #(updated2, result) =
    widget.dispatch_llm(
      handle: updated,
      tool_name: "close_directory",
      args: close_args,
    )
  result
  |> should.equal(Ok("Closed directory: ."))

  // Should be back to empty
  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated2)
  string.contains(text, "No directory or file open.")
  |> should.be_true
}

pub fn close_nonexistent_directory_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("/not/open"))])
  let #(_updated, result) =
    widget.dispatch_llm(
      handle: handle,
      tool_name: "close_directory",
      args: args,
    )
  let assert Ok(text) = result
  string.contains(text, "No directory is open")
  |> should.be_true
}

pub fn close_read_file_via_llm_test() {
  let handle = file_explorer.create()
  // Open a file first
  let args = make_args([#("path", json.string("gleam.toml"))])
  let #(updated, _) =
    widget.dispatch_llm(handle: handle, tool_name: "read_file", args: args)
  // Close it
  let close_args = make_args([#("path", json.string("gleam.toml"))])
  let #(updated2, result) =
    widget.dispatch_llm(
      handle: updated,
      tool_name: "close_read_file",
      args: close_args,
    )
  result
  |> should.equal(Ok("Closed: gleam.toml"))

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated2)
  string.contains(text, "No directory or file open.")
  |> should.be_true
}

// ============================================================================
// Re-open refreshes listing
// ============================================================================

pub fn reopen_directory_refreshes_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("."))])
  let #(updated, _) =
    widget.dispatch_llm(handle: handle, tool_name: "open_directory", args: args)
  // Open same directory again — should replace, not duplicate
  let #(updated2, _) =
    widget.dispatch_llm(
      handle: updated,
      tool_name: "open_directory",
      args: args,
    )

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated2)
  // Should only have one "Contents of" section
  let count =
    string.split(text, "Contents of")
    |> list.length
  // 1 before + 1 after the split = 2 parts means 1 occurrence
  count
  |> should.equal(2)
}

// ============================================================================
// UI event dispatch tests
// ============================================================================

pub fn open_directory_via_ui_test() {
  let handle = file_explorer.create()
  let args = make_args([#("path", json.string("."))])
  let #(updated, result) =
    widget.dispatch_ui(handle: handle, event_name: "open_directory", args: args)
  // UI dispatch with CmdEffect → CmdToolResult → Some(result)
  result
  |> should.equal(Some("Opened directory: ."))

  let assert [message.Request(parts: [message.UserPart(text)])] =
    widget.view_messages(updated)
  string.contains(text, "Contents of `.`")
  |> should.be_true
}

pub fn unknown_event_via_ui_test() {
  let handle = file_explorer.create()
  let args = make_args([])
  let #(_updated, result) =
    widget.dispatch_ui(handle: handle, event_name: "unknown", args: args)
  result
  |> should.equal(None)
}

// ============================================================================
// Unknown tool test
// ============================================================================

pub fn unknown_tool_via_llm_test() {
  let handle = file_explorer.create()
  let args = make_args([])
  let #(_updated, result) =
    widget.dispatch_llm(handle: handle, tool_name: "unknown", args: args)
  result
  |> should.equal(Error("FileExplorer: unknown tool 'unknown'"))
}

// ============================================================================
// Protocol-free verification
// ============================================================================

pub fn protocol_free_tools_test() {
  let handle = file_explorer.create()
  let free = widget.protocol_free_tools(handle)
  set.contains(free, "open_directory")
  |> should.be_true
  set.contains(free, "close_directory")
  |> should.be_true
  set.contains(free, "read_file")
  |> should.be_true
  set.contains(free, "close_read_file")
  |> should.be_true
}

// ============================================================================
// View tools test
// ============================================================================

pub fn view_tools_returns_four_tools_test() {
  let handle = file_explorer.create()
  let tools = widget.view_tools(handle)
  list.length(tools)
  |> should.equal(4)
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "open_directory")
  |> should.be_true
  list.contains(names, "close_directory")
  |> should.be_true
  list.contains(names, "read_file")
  |> should.be_true
  list.contains(names, "close_read_file")
  |> should.be_true
}

// ============================================================================
// Helpers
// ============================================================================

fn dynamic_decoder() -> decode.Decoder(dynamic.Dynamic) {
  decode.new_primitive_decoder("dynamic", fn(d) { Ok(d) })
}

fn make_args(fields: List(#(String, json.Json))) -> dynamic.Dynamic {
  let assert Ok(d) =
    json.parse(json.to_string(json.object(fields)), dynamic_decoder())
  d
}
