import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

import eddie/agent
import eddie/agent_tree
import eddie/http as eddie_http
import eddie/llm
import eddie_shared/agent_info

// ============================================================================
// Helpers
// ============================================================================

fn test_config() -> agent.AgentConfig {
  agent.AgentConfig(
    agent_id: "",
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
// Tests: Empty tree
// ============================================================================

pub fn start_empty_tree_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )
  // Tree starts empty
  let roots = agent_tree.get_tree(tree: tree)
  list.length(roots)
  |> should.equal(0)
}

pub fn get_nonexistent_agent_fails_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  agent_tree.get_agent(tree: tree, id: "nonexistent")
  |> should.be_error
}

// ============================================================================
// Tests: Spawn root agent
// ============================================================================

pub fn spawn_root_agent_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  agent_tree.spawn_root(
    tree: tree,
    id: "root-1",
    label: "Root 1",
    system_prompt: "You are root 1.",
  )
  |> should.be_ok

  // Agent should be accessible
  agent_tree.get_agent(tree: tree, id: "root-1")
  |> should.be_ok

  // Tree should have one root
  let roots = agent_tree.get_tree(tree: tree)
  list.length(roots)
  |> should.equal(1)

  let assert Ok(first) = list.first(roots)
  first.info.id
  |> should.equal("root-1")
  first.info.label
  |> should.equal("Root 1")
  first.info.parent_id
  |> should.equal(None)
}

pub fn spawn_root_agent_usable_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root 1",
      system_prompt: "You are root 1.",
    )

  let assert Ok(subject) = agent_tree.get_agent(tree: tree, id: "root-1")
  let result = agent.run_turn(subject: subject, text: "Hello", timeout: 10_000)
  case result {
    agent.TurnSuccess(text) -> text |> should.equal("OK")
    agent.TurnError(reason) -> {
      should.fail()
      panic as reason
    }
  }
}

pub fn spawn_duplicate_root_fails_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root 1",
      system_prompt: "test",
    )

  let result =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root 1 Again",
      system_prompt: "test",
    )
  case result {
    Error(agent_tree.AgentAlreadyExists(id)) -> id |> should.equal("root-1")
    _ -> should.fail()
  }
}

pub fn multiple_roots_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let assert Ok(_) =
    agent_tree.spawn_root(tree: tree, id: "r1", label: "R1", system_prompt: "a")
  let assert Ok(_) =
    agent_tree.spawn_root(tree: tree, id: "r2", label: "R2", system_prompt: "b")

  let roots = agent_tree.get_tree(tree: tree)
  list.length(roots)
  |> should.equal(2)
}

// ============================================================================
// Tests: Spawn child agent
// ============================================================================

pub fn spawn_child_agent_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root",
      system_prompt: "test",
    )

  let override =
    agent.AgentConfigOverride(
      model: Some("child-model"),
      api_base: None,
      system_prompt: Some("You are a child."),
    )

  agent_tree.spawn_child(
    tree: tree,
    id: "child-1",
    label: "Child 1",
    parent_id: "root-1",
    goal: "Investigate something",
    initial_message: "Please investigate X",
    override: override,
  )
  |> should.be_ok

  // Child should be accessible
  agent_tree.get_agent(tree: tree, id: "child-1")
  |> should.be_ok

  // Tree should show child under root
  let roots = agent_tree.get_tree(tree: tree)
  let assert Ok(root_node) = list.first(roots)
  list.length(root_node.children)
  |> should.equal(1)

  let assert Ok(child_node) = list.first(root_node.children)
  child_node.info.id
  |> should.equal("child-1")
  child_node.info.parent_id
  |> should.equal(Some("root-1"))
}

pub fn spawn_child_nonexistent_parent_fails_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let result =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-1",
      label: "Child",
      parent_id: "no-such-parent",
      goal: "test",
      initial_message: "test",
      override: override,
    )
  case result {
    Error(agent_tree.ParentNotFound(id)) -> id |> should.equal("no-such-parent")
    _ -> should.fail()
  }
}

pub fn spawn_grandchild_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root",
      system_prompt: "test",
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-1",
      label: "Child",
      parent_id: "root-1",
      goal: "test",
      initial_message: "test",
      override: override,
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "grandchild-1",
      label: "Grandchild",
      parent_id: "child-1",
      goal: "test",
      initial_message: "test",
      override: override,
    )

  // Tree should have depth 3
  let roots = agent_tree.get_tree(tree: tree)
  let assert Ok(root_node) = list.first(roots)
  let assert Ok(child_node) = list.first(root_node.children)
  let assert Ok(grandchild_node) = list.first(child_node.children)
  grandchild_node.info.id
  |> should.equal("grandchild-1")
  grandchild_node.info.parent_id
  |> should.equal(Some("child-1"))
}

// ============================================================================
// Tests: Get children / get parent
// ============================================================================

pub fn get_children_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root",
      system_prompt: "test",
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-a",
      label: "A",
      parent_id: "root-1",
      goal: "test",
      initial_message: "test",
      override: override,
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-b",
      label: "B",
      parent_id: "root-1",
      goal: "test",
      initial_message: "test",
      override: override,
    )

  let children = agent_tree.get_children(tree: tree, parent_id: "root-1")
  list.length(children)
  |> should.equal(2)
}

pub fn get_parent_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root",
      system_prompt: "test",
    )
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-1",
      label: "Child",
      parent_id: "root-1",
      goal: "test",
      initial_message: "test",
      override: override,
    )

  agent_tree.get_parent(tree: tree, child_id: "child-1")
  |> should.equal(Some("root-1"))

  // Root has no parent
  agent_tree.get_parent(tree: tree, child_id: "root-1")
  |> should.equal(None)
}

// ============================================================================
// Tests: Config merge (unchanged — still on agent module)
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

// ============================================================================
// Tests: Status updates
// ============================================================================

pub fn update_status_test() {
  let assert Ok(tree) =
    agent_tree.start_with_send_fn(
      config: test_config(),
      send_fn: mock_send_fn(),
    )

  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "root-1",
      label: "Root",
      system_prompt: "test",
    )

  agent_tree.update_status(
    tree: tree,
    agent_id: "root-1",
    status: agent_info.AgentRunning,
  )

  // Status should be reflected in the tree
  let roots = agent_tree.get_tree(tree: tree)
  let assert Ok(root_node) = list.first(roots)
  root_node.info.status
  |> should.equal(agent_info.AgentRunning)
}
