# dx and the wasm toolchain around it, for repos with a Dioxus app.
#
# Imported as `devenv-fleet/dioxus`. The repo's devenv.yaml must also
# declare the `nixpkgs-dx` input at pins.json's revision (dx, binaryen and
# wasm-bindgen build from it), and import `devenv-fleet/rust`.
{ pkgs, lib, config, inputs, ... }:
let
  cfg = config.fleet.dioxus;
  pkgsDx = import inputs.nixpkgs-dx { inherit (pkgs.stdenv) system; };
in
{
  options.fleet.dioxus = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/dx.nix { inherit pkgsDx; };
      defaultText = lib.literalMD "the fleet's dx (pkgs/dx.nix)";
      description = "The dx on PATH. Override per repo only while moving between dx revisions.";
    };
    wasmBindgen = lib.mkOption {
      type = with lib.types; submodule {
        options = {
          version = lib.mkOption { type = str; };
          hash = lib.mkOption { type = str; };
          cargoHash = lib.mkOption { type = str; };
        };
      };
      # Task's and Keyflow's Cargo.lock (Studio is on 0.2.126).
      default = {
        version = "0.2.127";
        hash = "sha256-di+qBAdd7pENLiIB9CoZoab+W5xeDoByMREcCGTSzWo=";
        cargoHash = "sha256-FTv2GZIAQs0ePdIZXIXil7JbZ6kIT05VG6vqC1qNFxQ=";
      };
      description = "wasm-bindgen-cli, matching the workspace Cargo.lock's wasm-bindgen.";
    };
  };

  config = {
    packages = [
      cfg.package
      pkgsDx.binaryen # the wasm-opt dx expects
      (pkgs.callPackage ../pkgs/wasm-bindgen-cli.nix ({ inherit pkgsDx; } // cfg.wasmBindgen))
      pkgs.tailwindcss_4
    ];

    # dx leaves the rustc wrapper to kache in base builds (the patch).
    env.DX_NO_RUSTC_WRAPPER = "1";

    # Unwrapped clang for C in wasm crates (ring): the nix cc-wrapper injects
    # hardening flags wasm32 rejects and leaks glibc headers. Builtin headers
    # come from the unwrapped clang's lib output. darwin/ replaces CC with a
    # DYLD-clean wrapper.
    env.CC_wasm32_unknown_unknown = lib.mkDefault "${pkgs.llvmPackages_18.clang-unwrapped}/bin/clang";
    env.AR_wasm32_unknown_unknown = "${pkgs.llvmPackages_18.bintools-unwrapped}/bin/llvm-ar";
    # The builtin headers from the unwrapped clang's lib output, not the
    # cc-wrapper's resource-root: the wrapper pulls in compiler-rt, which
    # nix builds from source on macOS, and LLVM 18's compiler-rt does not
    # build against the Apple SDK's libc++ 21 (`__builtin_ctzg`). That broke
    # every dev shell with this module on the Macs.
    env.CFLAGS_wasm32_unknown_unknown =
      let clang = pkgs.llvmPackages_18.clang-unwrapped;
      in "-isystem ${clang.lib}/lib/clang/${lib.versions.major clang.version}/include";
  };
}
