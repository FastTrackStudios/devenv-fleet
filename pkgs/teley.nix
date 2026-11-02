# Teley (logaretm/teley), run locally: its Cloudflare worker (OTLP ingest at
# `/r/<room>`, the live WebSocket feed, the TelemetryRoom Durable Object)
# plus the static dashboard, served by nixpkgs' wrangler, whose workerd is
# patched for NixOS. The npm workerd in node_modules is dynamically linked and
# runs only on hosts with nix-ld, so it is never used.
#
# Built once, used by two launchers: the `telemetry` module's process and
# (later) an always-on home-manager service. `teley-worker` serves on
# 127.0.0.1:${TELEY_PORT:-8787}; state lives under
# ${XDG_STATE_HOME:-~/.local/state}/teley.
{ lib
, stdenvNoCC
, fetchFromGitHub
, nodejs_24
, pnpm_11
, fetchPnpmDeps
, pnpmConfigHook
, wrangler
, makeWrapper
, coreutils
}:
let
  pin = (lib.importJSON ../pins.json).teley;
  # Teley pins pnpm 11; its scripts run on nodejs_24 (engines: node >= 24).
  pnpm = pnpm_11;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "teley";
  version = "0-unstable-${builtins.substring 0 7 pin.rev}";

  src = fetchFromGitHub {
    inherit (pin) owner repo rev;
    hash = pin.hash;
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = pin.pnpmDepsHash;
  };

  nativeBuildInputs = [ nodejs_24 pnpm pnpmConfigHook wrangler makeWrapper ];

  env = {
    NUXT_TELEMETRY_DISABLED = "1";
    WRANGLER_SEND_METRICS = "false";
  };

  buildPhase = ''
    runHook preBuild
    # The dashboard: web/.output/public, the worker's [assets] directory.
    pnpm --dir web generate
    # The worker, bundled with its dependencies (@sentry/cloudflare), so
    # the output needs no node_modules.
    (cd workers && HOME=$TMPDIR wrangler deploy --dry-run --outdir "$TMPDIR/worker")
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/teley/worker $out/share/teley/public $out/bin
    cp -r web/.output/public/. $out/share/teley/public/
    cp "$TMPDIR"/worker/*.js $out/share/teley/worker/
    main=$(cd $out/share/teley/worker && ls index.js 2>/dev/null || ls *.js | head -1)
    # wrangler.toml with the bundle as main and the dashboard beside it.
    sed -e "s|^main = .*|main = \"worker/$main\"|" \
        -e 's|^directory = .*|directory = "public"|' \
        -e 's|^SENTRY_ENVIRONMENT = .*|SENTRY_ENVIRONMENT = "development"|' \
        workers/wrangler.toml > $out/share/teley/wrangler.toml
    grep -q "worker/$main" $out/share/teley/wrangler.toml
    grep -q 'directory = "public"' $out/share/teley/wrangler.toml

    # wrangler writes .wrangler/ beside its config, so it runs from a copy
    # in the state dir, refreshed whenever the build changes.
    cat > $out/bin/teley-worker <<EOF
    #!${stdenvNoCC.shell}
    set -eu
    state="\''${XDG_STATE_HOME:-\$HOME/.local/state}/teley"
    run="\$state/$(basename $out)"
    if [ ! -f "\$run/wrangler.toml" ]; then
      ${coreutils}/bin/mkdir -p "\$state"
      tmp=\$(${coreutils}/bin/mktemp -d "\$state/.tmp.XXXXXX")
      ${coreutils}/bin/cp -r $out/share/teley/. "\$tmp/"
      ${coreutils}/bin/chmod -R u+w "\$tmp"
      ${coreutils}/bin/mv "\$tmp" "\$run"
    fi
    cd "\$run"
    export WRANGLER_SEND_METRICS=false
    exec ${wrangler}/bin/wrangler dev \\
      --ip 127.0.0.1 --port "\''${TELEY_PORT:-8787}" \\
      --persist-to "\$state/do" --log-level "\''${TELEY_LOG_LEVEL:-warn}" "\$@"
    EOF
    chmod +x $out/bin/teley-worker
    runHook postInstall
  '';

  meta = {
    description = "Teley's worker and dashboard, served locally by wrangler dev";
    homepage = "https://github.com/logaretm/teley";
    license = lib.licenses.asl20;
    mainProgram = "teley-worker";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
