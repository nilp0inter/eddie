import gleam/erlang/process
import gleam/int
import gleam/result

import eddie/agent
import eddie/llm
import eddie/server

pub fn main() -> Nil {
  // Required — crashes at startup if not set
  let assert Ok(api_key) = get_env("OPENROUTER_API_KEY")

  let api_base =
    get_env("OPENROUTER_API_BASE")
    |> result.unwrap("https://openrouter.ai/api/v1")

  let model =
    get_env("EDDIE_MODEL")
    |> result.unwrap("anthropic/claude-sonnet-4")

  let port =
    get_env("EDDIE_PORT")
    |> result.try(int.parse)
    |> result.unwrap(8080)

  let config =
    agent.AgentConfig(
      llm_config: llm.LlmConfig(
        api_base: api_base,
        api_key: api_key,
        model: model,
      ),
      system_prompt: default_system_prompt(),
    )

  let assert Ok(agent_subject) = agent.start(config: config)

  let server_config = server.ServerConfig(port: port)
  let assert Ok(_) = server.start(config: server_config, agent: agent_subject)

  process.sleep_forever()
}

fn default_system_prompt() -> String {
  "You are Eddie, a helpful AI assistant. You work within a task-based workflow where your conversation is managed through tasks. Follow the task protocol carefully: create tasks, record memories aggressively, and close tasks when done."
}

@external(erlang, "eddie_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)
