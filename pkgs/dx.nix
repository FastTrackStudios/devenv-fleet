# The fleet's one dx (dioxus-cli): upstream 0.8.0-alpha.3 (the Dioxus the
# apps pin; dx refuses a mismatched one) with two patches: the wasm-split
# CLI half of DioxusLabs/dioxus#5668 (unmerged; fixes wasm-split's symbol
# resolution, which Task's web build needs; its core half is the dioxus
# library's, which apps take through their own pin), and Studio's
# DX_NO_RUSTC_WRAPPER patch.
# Revision and hashes are pins.json's `dx`. Built from nixpkgs-dx's
# dioxus-cli recipe (pkgsDx).
{ lib, pkgsDx }:
let
  pin = (lib.importJSON ../pins.json).dx;
in
pkgsDx.dioxus-cli.overrideAttrs (old: rec {
  inherit (pin) version;
  src = pkgsDx.fetchFromGitHub {
    inherit (pin) owner repo rev hash;
  };
  cargoDeps = pkgsDx.rustPlatform.fetchCargoVendor {
    inherit src;
    # The wasm-split patch adds a dependency line to Cargo.lock, so the
    # vendored tree is made from the patched lock.
    patches = [ ./dx-wasm-split-5668.patch ];
    name = "dioxus-cli-${version}-vendor";
    hash = pin.cargoHash;
  };
  # The dioxus repo; the CLI is a workspace member.
  buildAndTestSubdir = "packages/cli";
  # DX_NO_RUSTC_WRAPPER=1 makes a base (non-hot-patch) build run plain
  # cargo, so the host's kache RUSTC_WRAPPER caches workspace crates under
  # dx too and dx shares them with plain cargo. nixpkgs' 0.7-era patches do
  # not apply to the fork.
  patches = [ ./dx-wasm-split-5668.patch ./dx-no-rustc-wrapper.patch ];
  doCheck = false;
  doInstallCheck = false;
})
