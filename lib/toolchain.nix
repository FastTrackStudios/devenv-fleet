# The fleet's Rust toolchain: the one expression every devenv shell (rust/)
# and every packaging flake (flake.nix `lib.toolchainFor`) evaluates, so the
# store path is identical in a shell, in CI and in a release build. With the
# pinned nixpkgs and rust-overlay it is pins.json's `rust.toolchain` path.
#
# extraTargets changes the store path. A repo that needs more targets
# (Android) should add them in a profile, not in its default shell.
{ lib, pkgs, extraTargets ? [ ] }:
let
  pins = lib.importJSON ../pins.json;
in
assert lib.assertMsg (pkgs ? rust-bin) ''
  devenv-fleet: pkgs.rust-bin is missing. Add the rust-overlay input with
  `overlays: [ default ]` to devenv.yaml (see devenv-fleet's README).
'';
pkgs.rust-bin.stable.${pins.rust.version}.default.override {
  extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
  targets = [ "wasm32-unknown-unknown" ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      "aarch64-apple-ios"
      "aarch64-apple-ios-sim"
      "x86_64-apple-darwin"
    ]
    ++ extraTargets;
}
