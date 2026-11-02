# Pins only, for the packaging flakes that stay beside devenv (Task, Studio,
# Keyflow): `inputs.devenv-fleet.url = "github:FastTrackStudios/devenv-fleet/<tag>"`
# with `nixpkgs.follows = "devenv-fleet/nixpkgs"` and
# `rust-overlay.follows = "devenv-fleet/rust-overlay"`, then
# `devenv-fleet.lib.toolchainFor pkgs` for the same rustc as the shells.
# The revisions below are pins.json's; scripts/fleet-pins checks flake.lock.
# Dev environments do not use this file: they import the devenv modules.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    rust-overlay = {
      url = "github:oxalica/rust-overlay/5b9f1198b59bcb31c5c3250b332e7d77590e6306";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, rust-overlay, ... }: {
    lib = {
      pins = nixpkgs.lib.importJSON ./pins.json;
      # pkgs must carry rust-overlay (overlays.default below).
      toolchainFor = pkgs: import ./lib/toolchain.nix { inherit pkgs; inherit (pkgs) lib; };
    };
    overlays.default = rust-overlay.overlays.default;
  };
}
