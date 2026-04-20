# Taskfile Commands

Run `task --list` to see all available tasks. Key commands:

| Command | Purpose |
|---|---|
| `task start` | Build everything and run the server |
| `task build:local` | Build all packages (shared, backend, frontend + bundle) |
| `task backend:run` | Build backend + bundle frontend, then run the server |
| `task test:unit` | Run all tests (shared + backend) |
| `task format` | Auto-format all packages |
| `task format:check` | Check formatting across all packages (CI) |
| `task lint` | Format check + glinter |
| `task clean` | Remove compiled artefacts (keeps package cache) |
| `task docs:build` | Build documentation |
| `task docs:serve` | Serve docs with live reload |

Per-component commands follow a `component:target` pattern:

| Command | Purpose |
|---|---|
| `task shared:build` | Build the shared package |
| `task shared:test:unit` | Run shared tests |
| `task backend:build` | Build the backend |
| `task backend:test:unit` | Run backend tests |
| `task backend:lint` | Format check + glinter for backend |
| `task backend:run` | Build backend + bundle frontend, then run the server |
| `task frontend:build` | Build the frontend (Gleam → JS) |
| `task frontend:bundle` | Build + bundle frontend JS for browser (esbuild) |

## Local workflow

The correct order for local development:

1. `task test:unit` — run tests, fix until green
2. `task backend:lint` — run linter, fix warnings
3. `task format` — format only once, at the end

Never format before tests and lint pass.

## Lint

The `task backend:lint` command runs two checks in sequence:

1. `gleam format --check` — verifies formatting without modifying files
2. `gleam run -m glinter` — runs the glinter static analysis tool

Glinter is a dev dependency (`gleam add --dev glinter`) that checks for common issues: missing labels, stringly-typed errors, deep nesting, unused exports, and more.
