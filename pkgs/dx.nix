# The fleet's one dx (dioxus-cli): the Brahmastra-Labs fork Task builds
# (DioxusLabs/dioxus#5668's branch, which fixes wasm-split's symbol
# resolution), with Studio's DX_NO_RUSTC_WRAPPER patch rebased onto it.
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
    name = "dioxus-cli-${version}-vendor";
    hash = pin.cargoHash;
  };
  # The fork is the dioxus repo; the CLI is a workspace member.
  buildAndTestSubdir = "packages/cli";
  # DX_NO_RUSTC_WRAPPER=1 makes a base (non-hot-patch) build run plain
  # cargo, so the host's kache RUSTC_WRAPPER caches workspace crates under
  # dx too and dx shares them with plain cargo. nixpkgs' 0.7-era patches do
  # not apply to the fork.
  patches = [ ./dx-no-rustc-wrapper.patch ];
  doCheck = false;
  doInstallCheck = false;
})
