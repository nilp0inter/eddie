{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Minimal package set used by every CI step. Keeping this small
      # makes the CI Nix cache closure significantly smaller.
      ciPackages = with pkgs; [
        gleam          # gleam compiler
        erlang         # erlang runtime (gleam target)
        nodejs         # javascript target support
        rebar3         # erlang build tool (gleam dependency)
        go-task        # task runner
        mdbook         # documentation builder
      ];

      # Local-dev-only tools layered on top of the CI packages. These
      # are intentionally absent from the `ci` shell so they are never
      # fetched on the CI runner.
      devOnlyPackages = with pkgs; [
      ];
    in
    {
      devShells.${system} = {
        # The minimal shell used by `.github/workflows/ci.yml`. Invoke
        # via `nix develop .#ci`.
        ci = pkgs.mkShell {
          packages = ciPackages;
        };

        # The full local-development shell. Activated by direnv via
        # `.envrc`. Extends the CI shell with developer-only tools.
        default = pkgs.mkShell {
          packages = ciPackages ++ devOnlyPackages;
        };
      };
    };
}
