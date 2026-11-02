# devenv-fleet

The FastTrackStudios fleet's shared [devenv](https://devenv.sh) modules and
pins. Every fleet Rust repo imports them, so each dev shell, each CI job and
each release build compiles with **one rustc store path**, one gcc, mold and
glibc, and kache shares their builds across repos.

Written for devenv **2.4.0**.

| Module | What it gives a repo |
|---|---|
| `rust` | The fleet toolchain (`lib/toolchain.nix`: rust-overlay's `rust-bin.stable."1.99.1"` with rust-src, rust-analyzer, clippy, rustfmt and wasm32), mold as the linker, cargo-hakari, prek, cargo-rail, just, `RUST_SRC_PATH`, a `fleet-doctor` script, and prek's hooks in repos with a `prek.toml` |
| `dioxus` | The fleet's one dx (the Brahmastra-Labs fork plus `pkgs/dx-no-rustc-wrapper.patch`, `DX_NO_RUSTC_WRAPPER=1`), binaryen, wasm-bindgen-cli, tailwindcss and the wasm32 C toolchain |
| `telemetry` | `devenv up` runs a local Teley on :8787 (the room in `~/.teley/session.json`, which Claude's Teley MCP subscribes to) and an OpenTelemetry Collector on :4318 that batches and forwards to it |
| `darwin` | iOS and macOS: xcrun linker wrappers, `IPHONEOS_DEPLOYMENT_TARGET`, `DYLD_LIBRARY_PATH`. Inert on Linux |

`pins.json` is the one source of truth for the revisions: nixpkgs,
rust-overlay, nixpkgs-dx, the dx fork, Teley, the rustc store path each
system should get, and the devenv that CI bootstraps.

## Importing it

On 2.4.0 a remote import's own `devenv.yaml` is not evaluated, so each
module is a `devenv.nix` only and the importing repo declares the inputs.
A repo's `devenv.yaml`:

```yaml
require_version: ">=2.4.0"
strict_ports: true            # with `telemetry`: 8787 and 4318 never move
inputs:
  nixpkgs:
    url: github:NixOS/nixpkgs/<pins.json nixpkgs.rev>
  rust-overlay:
    url: github:oxalica/rust-overlay/<pins.json rust-overlay.rev>
    inputs:
      nixpkgs:
        follows: nixpkgs
    overlays:
      - default
  nixpkgs-dx:                 # with `dioxus` only
    url: github:NixOS/nixpkgs/<pins.json nixpkgs-dx.rev>
  devenv-fleet:
    url: github:FastTrackStudios/devenv-fleet/v0.1.0
    flake: false
imports:
  - devenv-fleet/rust
  - devenv-fleet/dioxus      # optional
  - devenv-fleet/telemetry   # optional
  - devenv-fleet/darwin      # optional
```

Then the repo's own `devenv.nix` adds its libraries, env and processes.

Don't write the revisions by hand. From a checkout of this repo at the tag
you want:

```sh
scripts/fleet-pins --write /path/to/repo   # rewrite devenv.yaml, then devenv update
scripts/fleet-pins /path/to/repo           # check devenv.yaml, devenv.lock and flake.lock; exit 1 on drift
```

A repo that keeps a packaging `flake.nix` takes the same pins from this
repo's `flake.nix`: `inputs.devenv-fleet.url = "github:FastTrackStudios/devenv-fleet/<tag>"`,
`nixpkgs.follows = "devenv-fleet/nixpkgs"`, `rust-overlay.follows = "devenv-fleet/rust-overlay"`,
and `devenv-fleet.lib.toolchainFor pkgs` for the toolchain.

## Rules

- **`.envrc` must load devenv's direnvrc before `use devenv`.** A bare
  `use devenv` fails with `use_devenv: command not found`, and in an agent
  shell that error is silent, so the agent falls back to whatever rustc is on
  the host PATH:

  ```bash
  eval "$(devenv direnvrc)"
  use devenv
  ```

- **Never use devenv's dotenv** (`dotenv.enable`). It copies the whole `.env`
  file, secrets included, into the Nix store. Load `.env` with direnv's own
  `dotenv_if_exists .env`, after `use devenv`, and in a process with
  `set -a; [ -f .env ] && . ./.env; set +a`.
- **Don't let devenv pick the linker.** The `rust` module sets
  `languages.rust.clangLinker.enable = false`. devenv's Linux default passes
  `--ld-path=ld.lld`, which silently replaces the mold that
  `.cargo/config.toml`'s `-fuse-ld=mold` asks for. Don't set
  `languages.rust.rustflags` or `mold.enable` either: `RUSTFLAGS` replaces
  the fleet's `.cargo/config.toml` rustflags tables.
- **kache is the host's.** Dev hosts set it as cargo's `build.rustc-wrapper`;
  THEBATTLESHIP's runners set `RUSTC_WRAPPER`. devenv passes the host env
  through, so never set or unset `RUSTC_WRAPPER` in a shell.
- **Extra Rust targets change the rustc path.** `fleet.rust.extraTargets`
  belongs in a profile (`profiles.mobile.module`), not the default shell.
- **The OTLP env goes to processes only.** Merge
  `config.fleet.telemetry.processEnv` into a process's `env`; the shell gets
  none, so tests export nothing.

## Checking a shell

```sh
devenv shell -- fleet-doctor   # rustc path (exit 1 if not pins.json's), kache wrapper, linker
```

## CI

On a runner without devenv, take the pinned one (it is on cache.nixos.org):

```sh
nix build --no-link --print-out-paths "github:NixOS/nixpkgs/$(jq -r .devenv.nixpkgs pins.json)#devenv"
```

then run steps as `devenv shell -- bash -e {0}`.

## Licence

MIT OR Apache-2.0, at your option (`LICENSE-MIT`, `LICENSE-APACHE`).
