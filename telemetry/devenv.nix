# A local Teley and the OpenTelemetry Collector in front of it.
#
# Imported as `devenv-fleet/telemetry`. `devenv up` then runs:
#   teley    Teley's worker (pkgs/teley.nix) on 127.0.0.1:8787, the host
#            Claude's Teley MCP (`teley-cli mcp --host localhost:8787`)
#            subscribes to, in ~/.teley/session.json's room;
#   otelcol  the collector on 127.0.0.1:4318, the one endpoint apps export
#            to. It forwards to `/r/<room>` (Teley rejects the `/v1/<signal>`
#            suffix the SDK appends to OTEL_EXPORTER_OTLP_ENDPOINT) and
#            batches, since `wrangler dev` falls over at a request per call.
#
# Both are host singletons on fixed ports: set `strict_ports: true` in
# devenv.yaml. When another checkout's stack already answers, the process
# attaches (idles in its slot) instead of starting a second copy, so this
# checkout's `devenv down` never stops another's stack.
#
# The OTLP env goes only to processes that merge `config.fleet.telemetry.processEnv`
# into their `env`, never into the shell, so tests stay telemetry-free.
{ pkgs, lib, config, ... }:
let
  cfg = config.fleet.telemetry;
  teley = pkgs.callPackage ../pkgs/teley.nix { };
  otelcol = pkgs.opentelemetry-collector-contrib;
  curl = "${pkgs.curl}/bin/curl";
  jq = "${pkgs.jq}/bin/jq";
  session = "$HOME/.teley/session.json";

  # Teley-specific probe: a POST to an OTLP signal path gets Teley's 404 that
  # names `/r/{roomId}`. A stranger on 8787 does not pass it.
  teleyUp = "${curl} -s --max-time 2 -X POST http://127.0.0.1:${toString cfg.teleyPort}/r/probe/v1/traces | grep -q 'Post OTLP to /r/'";
  # The collector's health_check extension.
  otelcolUp = "${curl} -s --max-time 2 http://127.0.0.1:${toString cfg.healthPort}/ | grep -q 'Server available'";
  attachOr = probe: name: cmd: ''
    if ${probe}; then
      echo "${name}: already running on this host; attaching"
      exec sleep infinity
    fi
    ${cmd}
  '';

  endpoint = "http://127.0.0.1:${toString cfg.teleyPort}/r/@ROOM@";
  config-yaml = pkgs.writeText "otelcol.yaml" ''
    extensions:
      health_check: {endpoint: "127.0.0.1:${toString cfg.healthPort}"}
    receivers:
      otlp:
        protocols:
          http: {endpoint: "127.0.0.1:${toString cfg.otlpPort}"}
    exporters:
      # Queued and never retried: a viewer that is restarting loses only its
      # own copy, and wants now, not a backlog.
      otlp_http/teley:
        traces_endpoint: ${endpoint}
        logs_endpoint: ${endpoint}
        metrics_endpoint: ${endpoint}
        retry_on_failure: {enabled: false}
        sending_queue: {enabled: true, queue_size: 200}
    processors:
      # One request every two seconds, not one per span.
      batch: {timeout: 2s, send_batch_size: 4096}
      # Each series' latest every 15 s: at the apps' 5 s interval, a point
      # at a time, wrangler dev's proxy fell over (Studio's finding).
      interval: {interval: 15s}
      # The traces kept: any with an error, any of 5 ms or more (architect's
      # QuietCalls already drops quick clean calls to their metric).
      tail_sampling:
        decision_wait: 5s
        decision_cache: {sampled_cache_size: 100000}
        policies:
          - {name: errors, type: status_code, status_code: {status_codes: [ERROR]}}
          - {name: slow, type: latency, latency: {threshold_ms: 5}}
    service:
      extensions: [health_check]
      telemetry: {logs: {level: warn}, metrics: {level: none}}
      pipelines:
        traces: {receivers: [otlp], processors: [tail_sampling, batch], exporters: [otlp_http/teley]}
        metrics: {receivers: [otlp], processors: [interval, batch], exporters: [otlp_http/teley]}
        logs: {receivers: [otlp], processors: [batch], exporters: [otlp_http/teley]}
  '';
in
{
  options.fleet.telemetry = {
    enable = lib.mkEnableOption "the local Teley and OTLP collector" // { default = true; };
    teleyPort = lib.mkOption { type = lib.types.port; default = 8787; readOnly = true; };
    otlpPort = lib.mkOption { type = lib.types.port; default = 4318; readOnly = true; };
    healthPort = lib.mkOption { type = lib.types.port; default = 13133; readOnly = true; };
    package = lib.mkOption {
      type = lib.types.package;
      default = teley;
      readOnly = true;
      description = "Teley's worker (pkgs/teley.nix).";
    };
    processEnv = lib.mkOption {
      type = with lib.types; attrsOf str;
      readOnly = true;
      default = {
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:${toString cfg.otlpPort}";
        OTEL_METRIC_EXPORT_INTERVAL = "5000";
      };
      description = "Merge into a process's `env` to export to the local stack.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The room teley-cli uses (same file and shape it writes). Never printed.
    tasks."fleet:teley-session" = {
      exec = ''
        f=${session}
        [ -s "$f" ] && exit 0
        mkdir -p "$(dirname "$f")"
        umask 077
        ${jq} -n \
          --arg r "$(LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 12)" \
          --arg t "$(LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 24)" \
          '{roomId: $r, receiveToken: $t}' > "$f"
      '';
      status = "test -s ${session}";
      before = [ "devenv:processes:otelcol" ];
    };

    processes.teley = {
      exec = attachOr teleyUp "teley" "exec ${teley}/bin/teley-worker";
      ready.exec = teleyUp;
    };

    processes.otelcol = {
      exec = attachOr otelcolUp "otelcol" ''
        room=$(${jq} -r '.roomId // empty' ${session})
        [ -n "$room" ] || { echo "otelcol: no roomId in ${session}" >&2; exit 1; }
        mkdir -p "$DEVENV_STATE/otelcol"
        sed "s|@ROOM@|$room|g" ${config-yaml} > "$DEVENV_STATE/otelcol/config.yaml"
        exec ${otelcol}/bin/otelcol-contrib --config "$DEVENV_STATE/otelcol/config.yaml"
      '';
      after = [ "devenv:processes:teley" ];
      ready.exec = otelcolUp;
    };
  };
}
