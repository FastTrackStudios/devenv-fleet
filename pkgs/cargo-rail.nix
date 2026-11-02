# cargo-rail: CI change selection (`cargo rail plan`). nixpkgs carries a
# release that predates the plan contract, so it is built from the tag, with
# the fleet toolchain (rail's rust-version is newer than nixpkgs' rustc).
# Moved from task:nix/modules/cargo-rail.nix.
{ lib, makeRustPlatform, fetchFromGitHub, toolchain }:
let
  rustPlatform = makeRustPlatform { cargo = toolchain; rustc = toolchain; };
in
rustPlatform.buildRustPackage rec {
  pname = "cargo-rail";
  version = "0.32.0";
  src = fetchFromGitHub {
    owner = "loadingalias";
    repo = "cargo-rail";
    rev = "v${version}";
    hash = "sha256-XdwwQVv3OIauYefmQNq6CKK/fcaEnmq6Rkilmg9bhk8=";
  };
  cargoHash = "sha256-kpFJ3/s1qgXqY7Nhci7/4YtMcw7E+UmB3SX8F5MHoxs=";
  doCheck = false;
  meta = {
    description = "Cargo-native monorepo change selection (plan), unify, release";
    homepage = "https://github.com/loadingalias/cargo-rail";
    license = lib.licenses.mit;
    mainProgram = "cargo-rail";
  };
}
