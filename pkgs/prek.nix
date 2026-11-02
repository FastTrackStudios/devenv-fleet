# prek, the git hook manager (j178/prek), as its upstream release binary.
# nixpkgs lags upstream, and the static musl builds run on NixOS as they are.
# Moved from task:nix/modules/prek.nix.
{ lib, stdenvNoCC, fetchurl, system }:
let
  version = "0.5.7";
  targets = {
    x86_64-linux = { target = "x86_64-unknown-linux-musl"; sha256 = "25d6a0316125127aed3ad7010128884d7e7243c4ac06f084218b98dc20020ca9"; };
    aarch64-linux = { target = "aarch64-unknown-linux-musl"; sha256 = "022ddbaef649d83ab7e0cfde13400612b896b04cce338623205525560d47bcf6"; };
    x86_64-darwin = { target = "x86_64-apple-darwin"; sha256 = "12b65c6685fc44ff9130c0bf5dcb01be69c0c81d9a0709553fd369c3b2010815"; };
    aarch64-darwin = { target = "aarch64-apple-darwin"; sha256 = "800c5b9c8239045bbdf4201957dd4175135e216e838c40a6ec1904ff18ebaf2c"; };
  };
  t = targets.${system} or (throw "prek: no release binary for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "prek";
  inherit version;
  src = fetchurl {
    url = "https://github.com/j178/prek/releases/download/v${version}/prek-${t.target}.tar.gz";
    inherit (t) sha256;
  };
  sourceRoot = "prek-${t.target}";
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    install -Dm755 prek "$out/bin/prek"
  '';
  meta = {
    description = "Git hook manager, a Rust reimplementation of pre-commit";
    homepage = "https://github.com/j178/prek";
    license = lib.licenses.mit;
    mainProgram = "prek";
  };
}
