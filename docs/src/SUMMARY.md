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
- [Technical Debt](./decisions/tech-debt.md)
