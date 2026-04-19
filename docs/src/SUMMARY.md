# Summary

[Introduction](./introduction.md)

# Vision & Goals

- [Vision & Strategy](./vision/README.md)

# System Overview

- [Architecture Overview](./overview/README.md)
  - [Components](./overview/components.md)

# Operations

- [Infrastructure](./infrastructure/README.md)
  - [Taskfile Commands](./infrastructure/taskfile.md)
  - [CI / GitHub Actions](./infrastructure/ci.md)

# Decisions & Debt

- [Trade-off Summary](./decisions/tradeoffs.md)
  - [Type erasure via closures](./decisions/tradeoffs/01-type-erasure-via-closures.md)
  - [Unsafe coercion for send](./decisions/tradeoffs/02-unsafe-coerce-for-send.md)
  - [Result types instead of panics](./decisions/tradeoffs/03-result-over-panic.md)
  - [Typed ConversationLog in Context](./decisions/tradeoffs/04-typed-conversation-log-in-context.md)
  - [Inline HTML over Lustre SPA](./decisions/tradeoffs/05-inline-html-over-lustre-spa.md)
  - [Synchronous turn in actor](./decisions/tradeoffs/06-synchronous-turn-in-actor.md)
  - [Dual-strategy structured output](./decisions/tradeoffs/07-dual-strategy-structured-output.md)
  - [Dynamic-to-JSON FFI roundtrip](./decisions/tradeoffs/08-dynamic-to-json-ffi-roundtrip.md)
  - [Agent tree without supervision](./decisions/tradeoffs/09-agent-tree-without-supervision.md)
  - [Token usage via Context rebuild](./decisions/tradeoffs/10-token-usage-via-context-rebuild.md)
  - [Simplifile sync IO in CmdEffect](./decisions/tradeoffs/11-simplifile-sync-io-in-cmdeffect.md)
  - [Client-side markdown rendering](./decisions/tradeoffs/12-client-side-markdown-rendering.md)
  - [Async agent with spawned effects](./decisions/tradeoffs/13-async-agent-with-spawned-effects.md)
  - [Closure-based widget injection](./decisions/tradeoffs/14-closure-based-widget-injection.md)
  - [Central mailbox broker](./decisions/tradeoffs/15-central-mailbox-broker.md)
- [Technical Debt](./decisions/tech-debt.md)
