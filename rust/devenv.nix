# The fleet's Rust environment: one rustc, mold, and the fleet's cargo tools.
#
# Imported as `devenv-fleet/rust` from a repo's devenv.yaml. That repo's
# devenv.yaml must also declare the `nixpkgs` and `rust-overlay` inputs at
# pins.json's revisions, rust-overlay with `overlays: [ default ]`.
{ pkgs, lib, config, ... }:
let
  cfg = config.fleet.rust;
  pins = lib.importJSON ../pins.json;
  toolchain = import ../lib/toolchain.nix {
    inherit lib pkgs;
    inherit (cfg) extraTargets;
  };
  prek = pkgs.callPackage ../pkgs/prek.nix { };
  cargo-rail = pkgs.callPackage ../pkgs/cargo-rail.nix { inherit toolchain; };
  # Only the default target set has a pinned path.
  expected = if cfg.extraTargets == [ ] then pins.rust.toolchain.${pkgs.stdenv.system} or "" else "";
in
{
  options.fleet = {
    rust = {
      extraTargets = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          Targets added to the fleet toolchain. Any entry changes the rustc
          store path, so kache stops sharing builds with the other repos.
          Put them in a profile, not in the default shell.
        '';
      };
      cargoRail.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Put cargo-rail (built from source with the fleet toolchain) on PATH.";
      };
      toolchain = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = toolchain;
        description = "The fleet toolchain, for a repo's own derivations.";
      };
    };
    banner = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines for the banner, which prints only to an interactive terminal.";
    };
  };

  config = {
    languages.rust = {
      enable = true;
      toolchainPackage = toolchain;
      # The GCC driver, as in every flake shell before devenv. With it,
      # .cargo/config.toml's `-C link-arg=-fuse-ld=mold` holds. devenv's
      # Linux default (clangLinker) sets the host linker to a clang wrapper
      # with `--ld-path=ld.lld`, which silently replaces mold with LLD.
      # Not `mold.enable` and not `rustflags` either: the fleet's rustflags
      # live in .cargo/config.toml, and RUSTFLAGS would replace those tables.
      clangLinker.enable = false;
      # rust-analyzer from the toolchain, not nixpkgs' newer one.
      lsp.package = toolchain;
    };

    # rust-analyzer finds no stdlib sources for a custom toolchainPackage.
    env.RUST_SRC_PATH = "${toolchain}/lib/rustlib/src/rust/library";

    # kache is host-provided and passes through: `build.rustc-wrapper` in
    # ~/.cargo/config.toml or /etc/kache/cargo-config.toml on dev hosts,
    # RUSTC_WRAPPER (and KACHE_*) on THEBATTLESHIP's runner units. Nothing
    # here sets or unsets RUSTC_WRAPPER, CARGO_HOME or CARGO_TARGET_DIR.
    packages = [
      pkgs.cargo-hakari
      pkgs.just
      pkgs.pkg-config
      prek
    ]
    ++ lib.optional cfg.cargoRail.enable cargo-rail
    # The linker .cargo/config.toml selects on x86_64 Linux; GCC accepts
    # -fuse-ld=mold natively.
    ++ lib.optional pkgs.stdenv.isLinux pkgs.mold;

    # prek's hooks, in repos with a prek.toml. A no-op once installed; the
    # hooks live in the common git dir, so a worktree shares them.
    tasks."fleet:hooks" = {
      exec = ''
        [ -f "$DEVENV_ROOT/prek.toml" ] || exit 0
        cd "$DEVENV_ROOT" && ${prek}/bin/prek install -q
      '';
      status = ''
        [ ! -f "$DEVENV_ROOT/prek.toml" ] \
          || [ -f "$(git -C "$DEVENV_ROOT" rev-parse --git-common-dir 2>/dev/null)/hooks/pre-commit" ]
      '';
      before = [ "devenv:enterShell" ];
    };

    # Quiet unless a person is at a terminal: direnv, agents, scripts and CI
    # get nothing on stdout. No version commands, no network.
    enterShell = ''
      if [ -t 1 ] && [ -t 2 ] && [[ $- == *i* ]] && [ -z "''${CI:-}" ] && [ -z "''${CLAUDECODE:-}" ]; then
        echo "devenv-fleet: rust ${pins.rust.version}, mold, kache via ''${RUSTC_WRAPPER:-cargo config}"
        ${lib.optionalString (config.fleet.banner != "") "printf '%s\\n' ${lib.escapeShellArg config.fleet.banner}"}
      fi
    '';

    # The toolchain and the wrapper this shell actually uses. Exits non-zero
    # when rustc is not the pinned store path, so CI can assert it.
    scripts.fleet-doctor.exec = ''
      rustc_path=$(readlink -f "$(command -v rustc)")
      toolchain=''${rustc_path%/bin/rustc}
      echo "rustc:    $toolchain"
      rustc -vV | sed -n 1p
      wrapper=''${RUSTC_WRAPPER:-}
      if [ -z "$wrapper" ]; then
        for f in "''${CARGO_HOME:-$HOME/.cargo}/config.toml" /etc/kache/cargo-config.toml; do
          [ -f "$f" ] && w=$(sed -n 's/^[[:space:]]*rustc-wrapper[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -1) \
            && [ -n "$w" ] && { wrapper="$w ($f)"; break; }
        done
      fi
      echo "wrapper:  ''${wrapper:-none}"
      ${lib.optionalString pkgs.stdenv.isLinux ''
        echo "linker:   $(cc -fuse-ld=mold -Wl,--version 2>/dev/null | head -1)"
      ''}
      expected=${lib.escapeShellArg expected}
      if [ -n "$expected" ] && [ "$toolchain" != "$expected" ]; then
        echo "fleet-doctor: rustc is not the pinned toolchain ($expected)" >&2
        exit 1
      fi
    '';
  };
}
