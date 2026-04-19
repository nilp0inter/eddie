# Taskfile Commands

Run `task --list` to see all available tasks. Key commands:

| Command | Purpose |
|---|---|
| `task build:local` | Build the project |
| `task format` | Auto-format source files |
| `task format:check` | Check formatting (CI) |
| `task lint` | Format check + glinter |
| `task tests:unit` | Run all tests |
| `task docs:build` | Build documentation |
| `task docs:serve` | Serve docs with live reload |

## Local workflow

The correct order for local development:

1. `gleam test` — run tests, fix until green
2. `gleam run -m glinter` — run linter, fix warnings
3. `gleam format src/ test/` — format only once, at the end

Never format before tests and lint pass. Always scope format to `src/` and `test/` to avoid touching `reference/` or other directories.

## Lint

The `task lint` command runs two checks in sequence:

1. `gleam format --check` — verifies formatting without modifying files
2. `gleam run -m glinter` — runs the glinter static analysis tool

Glinter is a dev dependency (`gleam add --dev glinter`) that checks for common issues: missing labels, stringly-typed errors, deep nesting, unused exports, and more.
