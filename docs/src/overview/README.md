# Architecture Overview

Eddie is a Gleam reimplementation of Calipso — an Elm-architecture widget system that builds shared context between a user and an AI agent. Each widget has a model, typed messages, a pure update function, and three views: LLM messages, LLM tools, and browser HTML.

## How it works

```mermaid
%%{init: {'flowchart': {'curve': 'natural'}}}%%
flowchart TB
    User((User)) <--> SPA["Lustre SPA"]
    SPA <--> Server["Mist Server"]
    Server <--> Agent["Agent Process"]
    Agent <--> Context["Context Compositor"]
    Context <--> Widgets["Widget Tree"]
    Agent <--> LLM["LLM API"]
```

The **agent loop** is the core cycle:

1. User sends a message through the browser
2. The agent composes a prompt from all widgets' `view_messages` and `view_tools`
3. The LLM responds with text or tool calls
4. Tool calls are dispatched to the owning widget via the Context compositor
5. The widget's `update` function produces a new model and a `Cmd`
6. The loop repeats until the LLM produces a text-only response

## Key differences from Calipso

| Aspect | Calipso (Python) | Eddie (Gleam) |
|---|---|---|
| Agent model | Mono-agent server | OTP multi-agent with hierarchical spawning |
| Frontend | htmx SPA (no build step) | Lustre SPA (compiled Gleam to JS) |
| Widget HTML | Plain HTML strings | Lustre element types (type-safe) |
| LLM client | Pydantic AI | glopenai (sans-IO) + gleam_httpc |
| Structured output | Pydantic AI built-in | Custom layer using sextant (JSON Schema) |
| State mutation | Mutable models (in-place) | Immutable models (update returns new value) |
| Type erasure | Python `Any` + duck typing | Opaque type with closures over typed internals |

## Widget tree

The agent's context is composed from a tree of widgets, orchestrated by the **Context compositor**:

- **SystemPrompt** — provides the agent's identity and framing text as a system message
- **ConversationLog** — manages task-partitioned conversation history, memory management, and the task protocol that governs when non-task tools can be called

Additional widgets (goal, token usage, file explorer) are planned for Phase 6.

## Context compositor and LLM bridge

The **Context** (`eddie/context`) is the root compositor that holds the widget tree, routes tool calls to their owning widgets, and enforces the task protocol before dispatch. It composes messages and tools from all widgets in a fixed order (system prompt → children → conversation log).

The **LLM bridge** (`eddie/llm`) converts between Eddie types and glopenai types in a sans-IO style — it builds HTTP requests and parses responses without performing network IO. The **HTTP layer** (`eddie/http`) is the only module that touches the network.

## Module map

See [Components](./components.md) for the full breakdown.
