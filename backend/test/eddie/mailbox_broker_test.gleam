import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{None, Some}
import gleeunit/should

import eddie/agent
import eddie/agent_tree
import eddie/http as eddie_http
import eddie/llm
import eddie/mailbox_broker

pub fn send_and_read_test() {
  let assert Ok(broker) = mailbox_broker.start()

  // Send from parent to child
  let result =
    mailbox_broker.send_mail(
      broker: broker,
      from: "parent-1",
      from_label: "Parent",
      to: "child-1",
      content: "Hello child",
    )
  result |> should.be_ok

  // Child should see the message
  let inbox = mailbox_broker.read_mail(broker: broker, agent_id: "child-1")
  case inbox {
    [msg] -> {
      msg.from |> should.equal("parent-1")
      msg.to |> should.equal("child-1")
      msg.content |> should.equal("Hello child")
      msg.read |> should.equal(False)
    }
    _ -> should.fail()
  }
}

pub fn send_and_read_unread_test() {
  let assert Ok(broker) = mailbox_broker.start()

  let assert Ok(_) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "parent-1",
      from_label: "Parent",
      to: "child-1",
      content: "Message 1",
    )

  let unread = mailbox_broker.read_unread(broker: broker, agent_id: "child-1")
  case unread {
    [msg] -> msg.content |> should.equal("Message 1")
    _ -> should.fail()
  }
}

pub fn outbox_test() {
  let assert Ok(broker) = mailbox_broker.start()

  let assert Ok(_) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "parent-1",
      from_label: "Parent",
      to: "child-1",
      content: "Outgoing",
    )

  let outbox = mailbox_broker.get_outbox(broker: broker, agent_id: "parent-1")
  case outbox {
    [msg] -> {
      msg.from |> should.equal("parent-1")
      msg.content |> should.equal("Outgoing")
    }
    _ -> should.fail()
  }
}

pub fn mark_read_test() {
  let assert Ok(broker) = mailbox_broker.start()

  let assert Ok(mail) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "a",
      from_label: "Agent A",
      to: "b",
      content: "test",
    )

  // Mark as read
  mailbox_broker.mark_read(broker: broker, agent_id: "b", message_id: mail.id)
  |> should.be_ok

  // Should have no unread now
  let unread = mailbox_broker.read_unread(broker: broker, agent_id: "b")
  unread |> should.equal([])

  // But still in inbox
  let inbox = mailbox_broker.read_mail(broker: broker, agent_id: "b")
  case inbox {
    [msg] -> msg.read |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn empty_inbox_test() {
  let assert Ok(broker) = mailbox_broker.start()

  let inbox = mailbox_broker.read_mail(broker: broker, agent_id: "nobody")
  inbox |> should.equal([])

  let unread = mailbox_broker.read_unread(broker: broker, agent_id: "nobody")
  unread |> should.equal([])
}

/// Integration test: spawn tree with broker, create parent and child,
/// send mail from parent to child via the broker, verify child can read it.
pub fn tree_integration_mail_delivery_test() {
  let config =
    agent.AgentConfig(
      agent_id: "",
      llm_config: llm.LlmConfig(
        api_base: "https://test.example.com/v1",
        api_key: "test-key",
        model: "test-model",
      ),
      system_prompt: "test",
      extra_widgets: [],
      on_turn_complete: option.None,
    )
  let send_fn = fn(_request: Request(String)) -> Result(
    Response(String),
    eddie_http.HttpError,
  ) {
    Ok(
      response.new(200)
      |> response.set_body(
        "{\"id\":\"1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"OK\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}",
      ),
    )
  }

  let assert Ok(tree) =
    agent_tree.start_with_send_fn(config: config, send_fn: send_fn)
  let assert Ok(broker) = mailbox_broker.start()
  agent_tree.set_broker(tree: tree, broker: broker)

  // Spawn parent
  let assert Ok(_) =
    agent_tree.spawn_root(
      tree: tree,
      id: "parent-1",
      label: "Parent",
      system_prompt: "test",
    )

  // Spawn child
  let override =
    agent.AgentConfigOverride(model: None, api_base: None, system_prompt: None)
  let assert Ok(_) =
    agent_tree.spawn_child(
      tree: tree,
      id: "child-1",
      label: "Child",
      parent_id: "parent-1",
      goal: "test",
      initial_message: "start",
      override: override,
    )

  // Send mail from parent to child via the SAME broker
  let assert Ok(mail) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "parent-1",
      from_label: "Parent",
      to: "child-1",
      content: "Hello from parent",
    )
  mail.from |> should.equal("parent-1")
  mail.to |> should.equal("child-1")

  // Child should be able to read the mail from the SAME broker
  let inbox = mailbox_broker.read_mail(broker: broker, agent_id: "child-1")
  case inbox {
    [msg] -> {
      msg.content |> should.equal("Hello from parent")
      msg.from |> should.equal("parent-1")
    }
    _ -> should.fail()
  }

  // Unread should also work
  let unread = mailbox_broker.read_unread(broker: broker, agent_id: "child-1")
  case unread {
    [msg] -> msg.content |> should.equal("Hello from parent")
    _ -> should.fail()
  }
}

pub fn multiple_messages_chronological_test() {
  let assert Ok(broker) = mailbox_broker.start()

  let assert Ok(_) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "a",
      from_label: "Agent A",
      to: "b",
      content: "First",
    )
  let assert Ok(_) =
    mailbox_broker.send_mail(
      broker: broker,
      from: "a",
      from_label: "Agent A",
      to: "b",
      content: "Second",
    )

  let inbox = mailbox_broker.read_mail(broker: broker, agent_id: "b")
  case inbox {
    [first, second] -> {
      first.content |> should.equal("First")
      second.content |> should.equal("Second")
    }
    _ -> should.fail()
  }
}
