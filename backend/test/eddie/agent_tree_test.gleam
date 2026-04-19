import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

import eddie/agent
import eddie/agent_tree
import eddie/http as eddie_http
import eddie/llm

// ============================================================================
// Helpers
// ============================================================================

fn test_config() -> agent.AgentConfig {
  agent.AgentConfig(
    agent_id: "root",
    llm_config: llm.LlmConfig(
      api_base: "https://test.example.com/v1",
      api_key: "test-key",
      model: "test-model",
    ),
    system_prompt: "You are a test assistant.",
  )
}

fn text_response_json(text: String) -> String {
  "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\""
  <> text
  <> "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
}

fn mock_send_fn() -> fn(Request(String)) ->
  Result(Response(String), eddie_http.HttpError) {
  fn(_request) {
    Ok(response.new(200) |> response.set_body(text_response_json("OK")))
  }
}

// ============================================================================
// Tests: Start tree
// ============================================================================

pub fn start_tree_test() {
  let result =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )
  result
  |> should.be_ok
}

pub fn root_returns_subject_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )
  // Root subject should be usable
  let result =
    agent.run_turn(
      subject: agent_tree.root(tree: tree),
      text: "Hello",
      timeout: 10_000,
    )
  case result {
    agent.TurnSuccess(text) -> text |> should.equal("OK")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

// ============================================================================
// Tests: Spawn child
// ============================================================================

pub fn spawn_child_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(
      model: Some("child-model"),
      api_base: None,
      system_prompt: Some("You are a child assistant."),
    )

  agent_tree.spawn_child(
    tree: tree,
    id: "child-1",
    label: "Child 1",
    override: override,
  )
  |> should.be_ok

  // Child should be accessible
  agent_tree.get_agent(tree: tree, id: "child-1")
  |> should.be_ok

  // Child should be usable
  let assert Ok(child) = agent_tree.get_agent(tree: tree, id: "child-1")
  let result =
    agent.run_turn(subject: child, text: "Hello child", timeout: 10_000)
  case result {
    agent.TurnSuccess(text) -> text |> should.equal("OK")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

pub fn spawn_duplicate_child_fails_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  agent_tree.spawn_child(
    tree: tree,
    id: "child-1",
    label: "Child 1",
    override: override,
  )
  |> should.be_ok

  // Spawning same ID again should fail
  let result =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-1",
      label: "Child 1",
      override: override,
    )
  case result {
    Error(agent_tree.ChildAlreadyExists(id)) -> id |> should.equal("child-1")
    _ -> should.fail()
  }
}

pub fn get_nonexistent_child_fails_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  agent_tree.get_agent(tree: tree, id: "nonexistent")
  |> should.be_error
}

pub fn get_root_by_id_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  // "root" should return the root agent
  agent_tree.get_agent(tree: tree, id: "root")
  |> should.be_ok
}

pub fn list_agents_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-a",
      label: "Agent A",
      override: override,
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-b",
      label: "Agent B",
      override: override,
    )

  let agents = agent_tree.list_agents(tree: tree)
  list.length(agents)
  |> should.equal(3)

  // Root should be first
  let assert Ok(first) = list.first(agents)
  first.id
  |> should.equal("root")
}

// ============================================================================
// Tests: Config merge
// ============================================================================

pub fn merge_config_full_override_test() {
  let parent = test_config()
  let override =
    agent.AgentConfigOverride(
      model: Some("new-model"),
      api_base: Some("https://new.example.com/v1"),
      system_prompt: Some("New system prompt"),
    )

  let child =
    agent.merge_config(parent: parent, child_id: "child-1", override: override)
  child.agent_id
  |> should.equal("child-1")
  child.llm_config.model
  |> should.equal("new-model")
  child.llm_config.api_base
  |> should.equal("https://new.example.com/v1")
  // API key always inherited from parent
  child.llm_config.api_key
  |> should.equal("test-key")
  child.system_prompt
  |> should.equal("New system prompt")
}

pub fn merge_config_partial_override_test() {
  let parent = test_config()
  let override =
    agent.AgentConfigOverride(
      model: Some("different-model"),
      api_base: None,
      system_prompt: None,
    )

  let child =
    agent.merge_config(parent: parent, child_id: "child-1", override: override)
  child.llm_config.model
  |> should.equal("different-model")
  // These should inherit from parent
  child.llm_config.api_base
  |> should.equal("https://test.example.com/v1")
  child.system_prompt
  |> should.equal("You are a test assistant.")
}

pub fn merge_config_no_override_test() {
  let parent = test_config()
  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let child =
    agent.merge_config(parent: parent, child_id: "child-1", override: override)
  child.llm_config.model
  |> should.equal("test-model")
  child.llm_config.api_base
  |> should.equal("https://test.example.com/v1")
  child.llm_config.api_key
  |> should.equal("test-key")
  child.system_prompt
  |> should.equal("You are a test assistant.")
}
