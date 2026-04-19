/// File Explorer widget — filesystem navigation and file reading.
///
/// Protocol-free: all tools work without an active task.
/// Uses CmdEffect for IO operations (directory listing, file reading).
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import simplifile

import eddie/cmd.{type Cmd}
import eddie/coerce
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}
import eddie_shared/initiator.{type Initiator, LLM, UI}
import eddie_shared/message.{type Message}

// ============================================================================
// Model
// ============================================================================

pub type OpenDirectory {
  OpenDirectory(
    path: String,
    entries: List(#(String, Bool)),
    listing_text: String,
  )
}

pub type FileExplorerModel {
  FileExplorerModel(
    open_directories: List(OpenDirectory),
    open_files: List(#(String, String)),
  )
}

// ============================================================================
// Messages
// ============================================================================

pub type FileExplorerMsg {
  // IO triggers — produce CmdEffect
  OpenDirectoryRequested(path: String)
  ReadFileRequested(path: String)
  // IO results — fed back from CmdEffect
  DirectoryOpened(
    path: String,
    entries: List(#(String, Bool)),
    listing_text: String,
  )
  DirectoryOpenError(error: String)
  FileRead(path: String, content: String)
  FileReadError(error: String)
  // Close actions — from LLM or UI
  CloseDirectory(path: String, initiator: Initiator)
  CloseReadFile(path: String, initiator: Initiator)
}

// ============================================================================
// Update
// ============================================================================

fn update(
  model: FileExplorerModel,
  msg: FileExplorerMsg,
) -> #(FileExplorerModel, Cmd(FileExplorerMsg)) {
  case msg {
    OpenDirectoryRequested(path) -> #(
      model,
      cmd.CmdEffect(
        perform: fn() { coerce.unsafe_coerce(do_open_directory(path)) },
        to_msg: coerce.unsafe_coerce,
      ),
    )
    ReadFileRequested(path) -> #(
      model,
      cmd.CmdEffect(
        perform: fn() { coerce.unsafe_coerce(do_read_file(path)) },
        to_msg: coerce.unsafe_coerce,
      ),
    )
    DirectoryOpened(path, entries, listing_text) -> {
      // Replace existing entry for the same path, or append
      let existing =
        list.filter(model.open_directories, fn(d) { d.path != path })
      let new_dir = OpenDirectory(path:, entries:, listing_text:)
      #(
        FileExplorerModel(
          ..model,
          open_directories: list.append(existing, [new_dir]),
        ),
        cmd.CmdToolResult("Opened directory: " <> path),
      )
    }
    DirectoryOpenError(error) -> #(model, cmd.CmdToolResult(error))
    FileRead(path, content) -> {
      let existing =
        list.filter(model.open_files, fn(entry) { entry.0 != path })
      #(
        FileExplorerModel(
          ..model,
          open_files: list.append(existing, [#(path, content)]),
        ),
        cmd.CmdToolResult("Opened: " <> path),
      )
    }
    FileReadError(error) -> #(model, cmd.CmdToolResult(error))
    CloseDirectory(path, initiator) -> {
      let has_dir = list.any(model.open_directories, fn(d) { d.path == path })
      case has_dir {
        False -> #(
          model,
          cmd.for_initiator(
            initiator: initiator,
            text: "No directory is open at: " <> path,
          ),
        )
        True -> {
          let remaining =
            list.filter(model.open_directories, fn(d) { d.path != path })
          #(
            FileExplorerModel(..model, open_directories: remaining),
            cmd.for_initiator(
              initiator: initiator,
              text: "Closed directory: " <> path,
            ),
          )
        }
      }
    }
    CloseReadFile(path, initiator) -> {
      let has_file = list.any(model.open_files, fn(entry) { entry.0 == path })
      case has_file {
        False -> #(
          model,
          cmd.for_initiator(
            initiator: initiator,
            text: "No file is open at: " <> path,
          ),
        )
        True -> {
          let remaining =
            list.filter(model.open_files, fn(entry) { entry.0 != path })
          #(
            FileExplorerModel(..model, open_files: remaining),
            cmd.for_initiator(initiator: initiator, text: "Closed: " <> path),
          )
        }
      }
    }
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: FileExplorerModel) -> List(Message) {
  let lines = ["## File Explorer"]
  let dir_lines =
    list.flat_map(model.open_directories, fn(directory) {
      ["", directory.listing_text]
    })
  let file_lines =
    list.flat_map(model.open_files, fn(entry) {
      let #(path, content) = entry
      ["", "**Open file:** `" <> path <> "`", "```", content, "```"]
    })
  let empty_line = case model.open_directories, model.open_files {
    [], [] -> ["No directory or file open."]
    _, _ -> []
  }
  let text =
    list.flatten([lines, dir_lines, file_lines, empty_line])
    |> string.join("\n")
  [message.Request(parts: [message.UserPart(text)])]
}

fn view_tools(_model: FileExplorerModel) -> List(ToolDefinition) {
  let assert Ok(open_dir) =
    tool.new(
      name: "open_directory",
      description: "Open a directory in the File Explorer, listing its files and subdirectories. Directories are marked with a trailing /. The listing persists until closed with close_directory. Re-opening the same path refreshes the listing.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "path",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("Directory path to open. Defaults to '.'."),
                ),
              ]),
            ),
          ]),
        ),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(close_dir) =
    tool.new(
      name: "close_directory",
      description: "Close an open directory in the File Explorer.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "path",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("Path of the directory to close.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["path"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(read_file) =
    tool.new(
      name: "read_file",
      description: "Read a file's contents.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "path",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("Path to the file to read.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["path"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(close_file) =
    tool.new(
      name: "close_read_file",
      description: "Close an open file in the File Explorer.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "path",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("Path of the file to close.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["path"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  [open_dir, close_dir, read_file, close_file]
}

fn view_html(model: FileExplorerModel) -> Element(Nil) {
  let root_button =
    html.button(
      [
        attribute.attribute(
          "onclick",
          "sendWidgetEvent('open_directory', {path: '.'})",
        ),
      ],
      [html.text("Root")],
    )

  let dir_entries =
    list.flat_map(model.open_directories, fn(directory) {
      let escaped_path = escape_js(directory.path)
      [
        html.div([], [
          html.code([], [html.text(directory.path)]),
          html.button(
            [
              attribute.attribute(
                "onclick",
                "sendWidgetEvent('close_directory', {path: '"
                  <> escaped_path
                  <> "'})",
              ),
            ],
            [html.text("\u{00d7}")],
          ),
        ]),
        html.ul(
          [],
          list.map(directory.entries, fn(entry) {
            let #(name, is_dir) = entry
            let full_path = escape_js(directory.path <> "/" <> name)
            case is_dir {
              True ->
                html.li(
                  [
                    attribute.style("cursor", "pointer"),
                    attribute.attribute(
                      "ondblclick",
                      "sendWidgetEvent('open_directory', {path: '"
                        <> full_path
                        <> "'})",
                    ),
                  ],
                  [html.text(name <> "/")],
                )
              False ->
                html.li(
                  [
                    attribute.style("cursor", "pointer"),
                    attribute.attribute(
                      "ondblclick",
                      "sendWidgetEvent('read_file', {path: '"
                        <> full_path
                        <> "'})",
                    ),
                  ],
                  [html.text(name)],
                )
            }
          }),
        ),
      ]
    })

  let file_entries =
    list.flat_map(model.open_files, fn(entry) {
      let #(path, content) = entry
      let escaped_path = escape_js(path)
      [
        html.div([], [
          html.code([], [html.text(path)]),
          html.button(
            [
              attribute.attribute(
                "onclick",
                "sendWidgetEvent('close_read_file', {path: '"
                  <> escaped_path
                  <> "'})",
              ),
            ],
            [html.text("\u{00d7}")],
          ),
        ]),
        html.pre([], [html.code([], [html.text(content)])]),
      ]
    })

  html.div([], [
    html.h3([], [html.text("File Explorer")]),
    root_button,
    ..list.append(dir_entries, file_entries)
  ])
}

/// Escape a string for safe embedding in a JavaScript single-quoted string literal.
fn escape_js(input: String) -> String {
  input
  |> string.replace("\\", "\\\\")
  |> string.replace("'", "\\'")
  |> string.replace("\n", "\\n")
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: FileExplorerModel,
  tool_name: String,
  args: Dynamic,
) -> Result(FileExplorerMsg, String) {
  case tool_name {
    "open_directory" -> {
      let path = decode_path_or_default(args, ".")
      Ok(OpenDirectoryRequested(path: path))
    }
    "close_directory" ->
      decode_path_required(args, tool_name)
      |> result.map(fn(path) { CloseDirectory(path: path, initiator: LLM) })
    "read_file" ->
      decode_path_required(args, tool_name)
      |> result.map(fn(path) { ReadFileRequested(path: path) })
    "close_read_file" ->
      decode_path_required(args, tool_name)
      |> result.map(fn(path) { CloseReadFile(path: path, initiator: LLM) })
    _ -> Error("FileExplorer: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: FileExplorerModel,
  event_name: String,
  args: Dynamic,
) -> Option(FileExplorerMsg) {
  case event_name {
    "open_directory" -> {
      let path = decode_path_or_default(args, ".")
      Some(OpenDirectoryRequested(path: path))
    }
    "close_directory" ->
      decode_path(args)
      |> option.map(fn(path) { CloseDirectory(path: path, initiator: UI) })
    "read_file" ->
      decode_path(args)
      |> option.map(fn(path) { ReadFileRequested(path: path) })
    "close_read_file" ->
      decode_path(args)
      |> option.map(fn(path) { CloseReadFile(path: path, initiator: UI) })
    _ -> None
  }
}

/// Decode a path from args, returning None if missing.
fn decode_path(args: Dynamic) -> Option(String) {
  option.from_result(decode.run(args, decode.at(["path"], decode.string)))
}

/// Decode a path from args, returning a default if missing.
fn decode_path_or_default(args: Dynamic, default: String) -> String {
  decode_path(args)
  |> option.unwrap(default)
}

/// Decode a required path from args, returning an error if missing.
fn decode_path_required(
  args: Dynamic,
  tool_name: String,
) -> Result(String, String) {
  case decode_path(args) {
    Some(path) -> Ok(path)
    None -> Error(tool_name <> ": missing 'path' field")
  }
}

// ============================================================================
// IO helpers — executed inside CmdEffect
// ============================================================================

/// List directory contents. Returns DirectoryOpened or DirectoryOpenError.
fn do_open_directory(path: String) -> FileExplorerMsg {
  case simplifile.is_directory(path) {
    Ok(True) -> read_directory_entries(path)
    _ -> DirectoryOpenError(error: "Not a directory: " <> path)
  }
}

/// Read and classify directory entries, building the listing text.
fn read_directory_entries(path: String) -> FileExplorerMsg {
  case simplifile.read_directory(path) {
    Error(_) -> DirectoryOpenError(error: "Failed to read directory: " <> path)
    Ok(names) -> {
      let sorted = list.sort(names, string.compare)
      let entries =
        list.map(sorted, fn(name) {
          let full_path = path <> "/" <> name
          let is_dir = result.unwrap(simplifile.is_directory(full_path), False)
          #(name, is_dir)
        })
      // Sort: directories first, then files
      let entries =
        list.sort(entries, fn(a, b) {
          case a.1, b.1 {
            True, False -> order.Lt
            False, True -> order.Gt
            _, _ -> string.compare(a.0, b.0)
          }
        })
      let listing_text = build_listing_text(path, entries)
      DirectoryOpened(path: path, entries: entries, listing_text: listing_text)
    }
  }
}

/// Format directory entries into a markdown listing.
fn build_listing_text(path: String, entries: List(#(String, Bool))) -> String {
  let header = "Contents of `" <> path <> "`:"
  let entry_lines =
    list.map(entries, fn(entry) {
      let #(name, is_dir) = entry
      let suffix = case is_dir {
        True -> "/"
        False -> ""
      }
      "- " <> name <> suffix
    })
  let body = case entry_lines {
    [] -> ["", "(empty directory)"]
    _ -> ["", ..entry_lines]
  }
  string.join([header, ..body], "\n")
}

/// Read file contents. Returns FileRead or FileReadError.
fn do_read_file(path: String) -> FileExplorerMsg {
  case simplifile.is_file(path) {
    Ok(True) ->
      case simplifile.read(path) {
        Ok(content) -> FileRead(path: path, content: content)
        Error(_) -> FileReadError(error: "Cannot read file: " <> path)
      }
    _ -> FileReadError(error: "File not found: " <> path)
  }
}

// ============================================================================
// Factory
// ============================================================================

/// Create a File Explorer widget handle with empty state.
pub fn create() -> WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "file_explorer",
    model: FileExplorerModel(open_directories: [], open_files: []),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_html: view_html,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.from_list([
      "open_directory", "close_directory", "read_file", "close_read_file",
    ]),
    protocol_free_tools: set.from_list([
      "open_directory", "close_directory", "read_file", "close_read_file",
    ]),
  ))
}
