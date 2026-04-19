import eddie/tool
import gleam/json
import gleam/option.{Some}
import gleeunit/should
import glopenai/chat

pub fn new_creates_tool_definition_test() {
  let schema =
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("name", json.object([#("type", json.string("string"))])),
        ]),
      ),
    ])

  let assert Ok(td) =
    tool.new(
      name: "greet",
      description: "Greet a user",
      parameters_json: schema,
    )

  td.name |> should.equal("greet")
  td.description |> should.equal("Greet a user")
}

pub fn to_chat_tool_produces_function_tool_test() {
  let schema =
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([])),
    ])

  let assert Ok(td) =
    tool.new(
      name: "my_tool",
      description: "Does things",
      parameters_json: schema,
    )
  let chat_tool = tool.to_chat_tool(td)

  case chat_tool {
    chat.FunctionTool(function: func) -> {
      func.name |> should.equal("my_tool")
      func.description |> should.equal(Some("Does things"))
      func.strict |> should.equal(Some(True))
    }
  }
}
