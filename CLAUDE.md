# Eddie

A harness for ralph loops, written in Gleam.

## Build & Test

All commands run inside the Nix devShell. Use `task` (go-task):

```sh
# Project-wide
task build:local     # build all packages
task test:unit       # run all tests
task format          # format all packages
task format:check    # check formatting (CI)
task lint            # format check + glinter

# Per-component (shared, backend, frontend)
task shared:build          task shared:test:unit
task backend:build         task backend:test:unit
task frontend:build        task frontend:bundle
task <component>:format    task <component>:format:check
task backend:lint

# Docs
task docs:build      # mdbook build (in docs/)
task docs:serve      # mdbook serve --open
```

### Workflow order

1. `task test:unit` — fix until green
2. `task backend:lint` — fix until clean
3. `task format` — only once, at the end

Never format before tests and lint pass.

## Project Structure

```
shared/                Gleam package: cross-target types and codecs
  src/eddie_shared/    Initiator, Message, Task, Tool, TurnResult, Protocol
  test/                45 tests (roundtrip codec tests)
backend/               Gleam package (Erlang target): server + agent
  src/
    eddie.gleam          Entry point (env config, start agent + server)
    eddie/
      agent.gleam        OTP actor: turn loop, subscriber notifications
      agent_tree.gleam   Hierarchical agent management (parent-child)
      server.gleam       mist HTTP + WebSocket server, serves Lustre SPA
      cmd.gleam          Cmd(msg) side-effect descriptors, Initiator type
      message.gleam      MessagePart, Message types, glopenai conversion
      tool.gleam         ToolDefinition type, glopenai conversion
      widget.gleam       WidgetConfig, WidgetHandle (type-erased), Cmd loop
      context.gleam      Context compositor, tool dispatch, protocol enforcement
      llm.gleam          Sans-IO LLM client bridge (glopenai)
      http.gleam         HTTP execution layer (gleam_httpc)
      coerce.gleam       Unsafe type coercion for type erasure boundary
      widgets/
        system_prompt.gleam    System prompt identity text
        conversation_log.gleam Task-partitioned conversation history
        task_protocol.gleam    Task types, protocol rules, enforcement
        goal.gleam             Protocol-free goal tracking
        file_explorer.gleam    Filesystem navigation (CmdEffect IO)
        token_usage.gleam      Display-only token tracking
    eddie_ffi.erl        Erlang FFI (identity, get_env)
  test/                  164 tests (gleeunit)
frontend/              Gleam package (JavaScript target): Lustre SPA
  src/
    eddie_frontend.gleam     Lustre app (Model, Msg, init, update, view)
    eddie_frontend_ffi.mjs   JS FFI (setTimeout, scrollToBottom)
  entrypoint.mjs         esbuild entrypoint
reference/             Read-only reference implementations
  calipso/             Python reference (Elm-architecture widgets)
  glopenai/            Gleam OpenAI client (published on hex.pm)
  sextant/             Gleam JSON Schema library (published on hex.pm)
  pydantic-ai/         Structured output spec
docs/                  mdBook documentation site
flake.nix              Two-tier Nix devShell (ci + default)
Taskfile.yml           All automation (component:target pattern)
PLAN.md                Phased implementation plan
```

## Conventions

- Target: Erlang (default Gleam target)
- Tests use gleeunit; test functions must end with `_test`
- Lint with glinter (`gleam run -m glinter`) before committing
- Format with `gleam format src/ test/` after lint passes
- CI runs in the `ci` devShell via `nix develop .#ci --command task <name>`
- Ignore `calipso/`, `glopenai/`, `pydantic-ai/`, `sextant/`, `nixos.qcow2` — reference material, not part of the build
- Dependencies `glopenai` and `sextant` are on hex.pm — never use local path deps
