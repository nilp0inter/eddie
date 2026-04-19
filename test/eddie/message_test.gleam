import eddie/message
import gleam/option.{None, Some}
import gleeunit/should
import glopenai/chat
import glopenai/shared

pub fn system_part_to_chat_message_test() {
  let msg = message.Request(parts: [message.SystemPart("You are helpful.")])
  let chat_messages = message.to_chat_messages([msg])

  case chat_messages {
    [chat.SystemMessage(content: chat.SystemTextContent(text), name: None)] ->
      text
    _ -> ""
  }
  |> should.equal("You are helpful.")
}

pub fn user_part_to_chat_message_test() {
  let msg = message.Request(parts: [message.UserPart("Hello!")])
  let chat_messages = message.to_chat_messages([msg])

  case chat_messages {
    [chat.UserMessage(content: chat.UserTextContent(text), name: None)] -> text
    _ -> ""
  }
  |> should.equal("Hello!")
}

pub fn text_response_to_chat_message_test() {
  let msg = message.Response(parts: [message.TextPart("Hi there!")])
  let chat_messages = message.to_chat_messages([msg])

  case chat_messages {
    [
      chat.AssistantMessage(
        content: Some(chat.AssistantTextContent(text)),
        refusal: None,
        name: None,
        tool_calls: None,
      ),
    ] -> text
    _ -> ""
  }
  |> should.equal("Hi there!")
}

pub fn tool_call_response_to_chat_message_test() {
  let msg =
    message.Response(parts: [
      message.ToolCallPart(
        tool_name: "create_task",
        arguments_json: "{\"description\":\"test\"}",
        tool_call_id: "call_123",
      ),
    ])
  let chat_messages = message.to_chat_messages([msg])

  case chat_messages {
    [
      chat.AssistantMessage(
        content: None,
        refusal: None,
        name: None,
        tool_calls: Some([
          chat.FunctionToolCall(
            id: "call_123",
            function: shared.FunctionCall(
              name: "create_task",
              arguments: "{\"description\":\"test\"}",
            ),
          ),
        ]),
      ),
    ] -> True
    _ -> False
  }
  |> should.be_true
}

pub fn tool_return_to_chat_message_test() {
  let msg =
    message.Request(parts: [
      message.ToolReturnPart(
        tool_name: "create_task",
        content: "Task created",
        tool_call_id: "call_123",
      ),
    ])
  let chat_messages = message.to_chat_messages([msg])

  case chat_messages {
    [chat.ToolMessage(content: chat.ToolTextContent(text), tool_call_id: id)] -> #(
      text,
      id,
    )
    _ -> #("", "")
  }
  |> should.equal(#("Task created", "call_123"))
}

pub fn from_chat_response_text_test() {
  let response =
    chat.CreateChatCompletionResponse(
      id: "chatcmpl-123",
      object: "chat.completion",
      created: 1_000_000,
      model: "gpt-4",
      choices: [
        chat.ChatChoice(
          index: 0,
          message: chat.ChatCompletionResponseMessage(
            role: chat.RoleAssistant,
            content: Some("Hello!"),
            refusal: None,
            tool_calls: None,
            annotations: None,
          ),
          finish_reason: Some(chat.Stop),
        ),
      ],
      usage: None,
      service_tier: None,
      system_fingerprint: None,
    )

  let assert Ok(msg) = message.from_chat_response(response)
  case msg {
    message.Response(parts: [message.TextPart(text)]) -> text
    _ -> ""
  }
  |> should.equal("Hello!")
}

pub fn from_chat_response_tool_calls_test() {
  let response =
    chat.CreateChatCompletionResponse(
      id: "chatcmpl-456",
      object: "chat.completion",
      created: 1_000_000,
      model: "gpt-4",
      choices: [
        chat.ChatChoice(
          index: 0,
          message: chat.ChatCompletionResponseMessage(
            role: chat.RoleAssistant,
            content: None,
            refusal: None,
            tool_calls: Some([
              chat.FunctionToolCall(
                id: "call_abc",
                function: shared.FunctionCall(
                  name: "set_goal",
                  arguments: "{\"goal\":\"test\"}",
                ),
              ),
            ]),
            annotations: None,
          ),
          finish_reason: Some(chat.ToolCalls),
        ),
      ],
      usage: None,
      service_tier: None,
      system_fingerprint: None,
    )

  let assert Ok(msg) = message.from_chat_response(response)
  case msg {
    message.Response(parts: [
      message.ToolCallPart(
        tool_name: "set_goal",
        arguments_json: "{\"goal\":\"test\"}",
        tool_call_id: "call_abc",
      ),
    ]) -> True
    _ -> False
  }
  |> should.be_true
}

pub fn from_chat_response_empty_choices_test() {
  let response =
    chat.CreateChatCompletionResponse(
      id: "chatcmpl-789",
      object: "chat.completion",
      created: 1_000_000,
      model: "gpt-4",
      choices: [],
      usage: None,
      service_tier: None,
      system_fingerprint: None,
    )

  message.from_chat_response(response)
  |> should.be_error
}

pub fn multiple_messages_to_chat_messages_test() {
  let messages = [
    message.Request(parts: [message.SystemPart("Be helpful.")]),
    message.Request(parts: [message.UserPart("Hi")]),
    message.Response(parts: [message.TextPart("Hello!")]),
  ]

  let chat_messages = message.to_chat_messages(messages)

  // Should produce 3 chat messages
  case chat_messages {
    [chat.SystemMessage(..), chat.UserMessage(..), chat.AssistantMessage(..)] ->
      True
    _ -> False
  }
  |> should.be_true
}
