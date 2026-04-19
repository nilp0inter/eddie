# CI / GitHub Actions

CI runs as a single job in `.github/workflows/ci.yml`. Every step executes inside the Nix `ci` devShell via `nix develop .#ci --command task <name>`.

Step order (fast-fail): format check, build, lint, tests, docs build.
