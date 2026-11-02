# macOS and iOS builds: moved from Task's toolchain (task:nix/modules/toolchain.nix).
#
# Imported as `devenv-fleet/darwin`, unconditionally: everything is behind
# `lib.mkIf isDarwin`, so it is inert on Linux. The fleet toolchain already
# carries the iOS and Intel targets on darwin (lib/toolchain.nix).
#
# No apple-sdk package here: the darwin stdenv carries one, and a second SDK
# in scope makes the cc wrapper abort with "Multiple conflicting values
# defined for DEVELOPER_DIR".
{ pkgs, lib, config, ... }:
let
  cfg = config.fleet.darwin;
  # The nix cc wrapper only targets macOS, so the iOS targets compile and
  # link through Xcode's clang via xcrun, with the nix SDK env scrubbed.
  iosCC = sdk: pkgs.writeShellScript "ios-clang-${sdk}" ''
    exec /usr/bin/env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk ${sdk} clang "$@"
  '';
  iosCXX = sdk: pkgs.writeShellScript "ios-clang++-${sdk}" ''
    exec /usr/bin/env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk ${sdk} clang++ "$@"
  '';
  # The wasm C compiler is clang-18, but DYLD_LIBRARY_PATH below makes it
  # load the stdenv's newer libclang-cpp (symbol mismatch, SIGABRT). Run it
  # with DYLD_LIBRARY_PATH unset so it resolves its own libraries.
  wasmCC = pkgs.writeShellScript "wasm-clang-18" ''
    exec /usr/bin/env -u DYLD_LIBRARY_PATH ${pkgs.llvmPackages_18.clang-unwrapped}/bin/clang "$@"
  '';
in
{
  options.fleet.darwin.libraries = lib.mkOption {
    type = with lib.types; listOf package;
    default = with pkgs; [ stdenv.cc.cc.lib fontconfig freetype openssl ];
    description = "Libraries on DYLD_LIBRARY_PATH, for test binaries and dlopen at run time.";
  };

  config = lib.mkIf pkgs.stdenv.isDarwin {
    packages = [ pkgs.libiconv ];
    env = {
      DYLD_LIBRARY_PATH = lib.makeLibraryPath cfg.libraries;
      CC_wasm32_unknown_unknown = "${wasmCC}";
      # Rust defaults aarch64-apple-ios to iOS 10, whose runtime lacks
      # `___chkstk_darwin` (libSystem has it since iOS 12); a large-stack
      # crate then fails to link. A modern floor for compile and link.
      IPHONEOS_DEPLOYMENT_TARGET = "15.0";
      CARGO_TARGET_AARCH64_APPLE_IOS_LINKER = "${iosCC "iphoneos"}";
      CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER = "${iosCC "iphonesimulator"}";
      CC_aarch64_apple_ios = "${iosCC "iphoneos"}";
      CXX_aarch64_apple_ios = "${iosCXX "iphoneos"}";
      CC_aarch64_apple_ios_sim = "${iosCC "iphonesimulator"}";
      CXX_aarch64_apple_ios_sim = "${iosCXX "iphonesimulator"}";
    };
  };
}
