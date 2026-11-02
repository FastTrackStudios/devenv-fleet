# devenv-fleet: agent instructions

The fleet's shared devenv modules (`rust/`, `dioxus/`, `telemetry/`,
`darwin/`) and their pins (`pins.json`). README.md says how a repo imports
them and lists the rules; read it first.

- Each module directory holds only a `devenv.nix`. On devenv 2.4.0 a remote
  import's `devenv.yaml` is not evaluated, so a module must not need one;
  importing repos declare the inputs.
- `pins.json` is the only place a revision lives. `flake.nix` repeats the
  nixpkgs and rust-overlay revisions for packaging flakes; `scripts/fleet-pins .`
  fails when they disagree. Moving nixpkgs moves every repo's rustc store
  path: update `rust.toolchain` in `pins.json` in the same change.
- Never set or unset `RUSTC_WRAPPER`, and never set `languages.rust.rustflags`,
  `mold.enable` or `clangLinker.enable = true` (see README "Rules").
- Before pushing: `tests/smoke/run.sh` (rustc path and mold), and build any
  package you touched against the pins (`pkgs/*.nix`; teley and dx are heavy,
  one at a time).
- Tags are immutable; a repo moves with `scripts/fleet-pins --write --ref <tag> <repo>`.
