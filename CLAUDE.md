# Eddie

A harness for ralph loops, written in Gleam.

## Build & Test

All commands run inside the Nix devShell. Use `task` (go-task):

```sh
task build:local     # gleam build
task tests:unit      # gleam test (depends on build)
task format          # gleam format src/ test/
task format:check    # gleam format --check (CI)
task lint            # format check + glinter
task docs:build      # mdbook build (in docs/)
task docs:serve      # mdbook serve --open
```

### Workflow order

1. `gleam test` — fix until green
2. `gleam run -m glinter` — fix until clean
3. `gleam format src/ test/` — only once, at the end

Never format before tests and lint pass. Always scope format to `src/` and `test/`.

## Project Structure

```
src/
  eddie.gleam          Entry point (env config, start agent + server)
  eddie/
    agent.gleam        OTP actor: turn loop, subscriber notifications
    agent_tree.gleam   Hierarchical agent management (parent-child)
    server.gleam       mist HTTP + WebSocket server, inline HTML frontend
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
      goal.gleam             Protocol-free goal tracking
      file_explorer.gleam    Filesystem navigation (CmdEffect IO)
      token_usage.gleam      Display-only token tracking
  eddie_ffi.erl        Erlang FFI (identity, get_env)
test/
  eddie/
    cmd_test.gleam
    message_test.gleam
    tool_test.gleam
    widget_test.gleam
    context_test.gleam
    llm_test.gleam
    agent_test.gleam
    agent_tree_test.gleam
    goal_test.gleam
    file_explorer_test.gleam
    token_usage_test.gleam
reference/             Read-only reference implementations
  calipso/             Python reference (Elm-architecture widgets)
  glopenai/            Gleam OpenAI client (published on hex.pm)
  sextant/             Gleam JSON Schema library (published on hex.pm)
  pydantic-ai/         Structured output spec
docs/                  mdBook documentation site
flake.nix              Two-tier Nix devShell (ci + default)
Taskfile.yml           All automation
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
