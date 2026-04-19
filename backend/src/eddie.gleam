import gleam/erlang/process
import gleam/int
import gleam/result

import eddie/agent
import eddie/agent_tree
import eddie/llm
import eddie/mailbox_broker
import eddie/server

pub fn main() -> Nil {
  // Required — crashes at startup if not set
  let assert Ok(api_key) = get_env("OPENROUTER_API_KEY")

  let api_base =
    get_env("OPENROUTER_API_BASE")
    |> result.unwrap("https://openrouter.ai/api/v1")

  let model =
    get_env("EDDIE_MODEL")
    |> result.unwrap("x-ai/grok-4.1-fast")

  let port =
    get_env("EDDIE_PORT")
    |> result.try(int.parse)
    |> result.unwrap(8080)

  // Base config — used as a template for all spawned agents.
  // No agent exists at startup; roots are created by the user.
  let base_config =
    agent.AgentConfig(
      agent_id: "",
      llm_config: llm.LlmConfig(
        api_base: api_base,
        api_key: api_key,
        model: model,
      ),
      system_prompt: default_system_prompt(),
      extra_widgets: [],
    )

  let assert Ok(tree) = agent_tree.start(config: base_config)
  let assert Ok(broker) = mailbox_broker.start()
  agent_tree.set_broker(tree: tree, broker: broker)

  let server_config = server.ServerConfig(port: port)
  let assert Ok(_) = server.start(config: server_config, tree: tree)

  process.sleep_forever()
}

fn default_system_prompt() -> String {
  "You are Eddie, a helpful AI assistant. You work within a task-based workflow where your conversation is managed through tasks. Follow the task protocol carefully: create tasks, record memories aggressively, and close tasks when done."
}

@external(erlang, "eddie_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)
