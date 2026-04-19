/// Tool definitions that widgets expose to the LLM.
/// Each tool has a name, description, and JSON Schema for its parameters.
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import glopenai/chat
import glopenai/shared

/// A tool that can be called by the LLM.
///
/// `parameters_schema` is a Dynamic holding the JSON Schema object for the
/// tool's parameters. This is kept as Dynamic because glopenai's
/// FunctionObject.parameters expects Dynamic, and the schema is generated
/// by sextant or built manually as a JSON value.
pub type ToolDefinition {
  ToolDefinition(name: String, description: String, parameters_schema: Dynamic)
}

pub type ToolError {
  JsonParseError(json.DecodeError)
}

/// Build a ToolDefinition from a name, description, and a json.Json schema.
/// Converts the Json value to Dynamic for storage.
pub fn new(
  name name: String,
  description description: String,
  parameters_json parameters_json: json.Json,
) -> Result(ToolDefinition, ToolError) {
  let json_string = json.to_string(parameters_json)
  use dynamic_value <- result.try(
    json.parse(json_string, decode.dynamic)
    |> result.map_error(JsonParseError),
  )
  Ok(ToolDefinition(
    name: name,
    description: description,
    parameters_schema: dynamic_value,
  ))
}

/// Convert to glopenai's ChatCompletionTool for inclusion in API requests.
pub fn to_chat_tool(tool: ToolDefinition) -> chat.ChatCompletionTool {
  chat.FunctionTool(function: shared.FunctionObject(
    name: tool.name,
    description: Some(tool.description),
    parameters: Some(tool.parameters_schema),
    strict: Some(True),
  ))
}
