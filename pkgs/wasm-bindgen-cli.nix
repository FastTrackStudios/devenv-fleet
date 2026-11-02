# wasm-bindgen-cli at the version a workspace's Cargo.lock resolves
# wasm-bindgen to; dx rejects a mismatch. Built through pkgsDx, whose
# fetchers reach static.crates.io (older pins' fetchers get a 403).
{ lib, pkgsDx, version, hash, cargoHash }:
pkgsDx.rustPlatform.buildRustPackage rec {
  pname = "wasm-bindgen-cli";
  inherit version cargoHash;
  src = pkgsDx.fetchCrate { inherit pname version hash; };
  nativeBuildInputs = [ pkgsDx.pkg-config ];
  buildInputs = lib.optionals pkgsDx.stdenv.isLinux [ pkgsDx.openssl ];
  doCheck = false;
}
