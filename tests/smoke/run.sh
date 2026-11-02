#!/usr/bin/env bash
# Evaluate the modules from this checkout in a scratch project and assert
# what every importing repo relies on: rustc is pins.json's store path, the
# linker is mold, and the modules evaluate. Needs devenv and jq.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/tests/smoke/." "$work/"
rm -f "$work/run.sh"
pin() { jq -r --arg n "$1" '.[$n] | "github:\(.owner)/\(.repo)/\(.rev)"' "$root/pins.json"; }
cat > "$work/devenv.yaml" <<YAML
require_version: ">=2.4.0"
strict_ports: true
inputs:
  nixpkgs:
    url: $(pin nixpkgs)
  rust-overlay:
    url: $(pin rust-overlay)
    inputs:
      nixpkgs:
        follows: nixpkgs
    overlays:
      - default
  nixpkgs-dx:
    url: $(pin nixpkgs-dx)
  devenv-fleet:
    url: path:$root
    flake: false
imports:
  - devenv-fleet/rust
  - devenv-fleet/telemetry
  - devenv-fleet/darwin
YAML
cd "$work"
git init -q
devenv shell -- fleet-doctor
# kache on PATH becomes RUSTC_WRAPPER; a host's own RUSTC_WRAPPER wins.
mkdir "$work/bin" && printf '#!/bin/sh\nexec "$@"\n' > "$work/bin/kache" && chmod +x "$work/bin/kache"
got=$(env -u RUSTC_WRAPPER PATH="$work/bin:$PATH" devenv shell -- sh -c 'echo "$RUSTC_WRAPPER"' | tail -1)
[ "$got" = "$work/bin/kache" ] || { echo "smoke: RUSTC_WRAPPER is '$got', want $work/bin/kache" >&2; exit 1; }
got=$(RUSTC_WRAPPER=/host/wrapper PATH="$work/bin:$PATH" devenv shell -- sh -c 'echo "$RUSTC_WRAPPER"' | tail -1)
[ "$got" = /host/wrapper ] || { echo "smoke: host RUSTC_WRAPPER overridden: '$got'" >&2; exit 1; }
devenv shell -- cargo build -q
comment=$(readelf -p .comment target/debug/fleet-smoke)
echo "$comment" | grep -q 'mold' || { echo "smoke: not linked by mold:"; echo "$comment"; exit 1; } >&2
echo "smoke: ok (mold)"
