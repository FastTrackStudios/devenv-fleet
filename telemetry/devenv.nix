# The local telemetry stack: OpenObserve and the OpenTelemetry Collector in
# front of it.
#
# Imported as `devenv-fleet/telemetry`. `devenv up` then runs:
#   openobserve  OpenObserve on 127.0.0.1:5080 (UI and API; gRPC on 5081):
#                traces, logs and metrics in one store on disk
#                (~/.local/state/openobserve), queried with SQL over HTTP or
#                in its UI. Kept `retentionDays` days, then compacted away.
#   otelcol      the collector on 127.0.0.1:4318, the one endpoint apps
#                export to. It batches, drops quick clean traces, and sends
#                to OpenObserve and to a rotating local file
#                (~/.local/state/otelcol/*.jsonl): the copy that survives
#                any viewer being down, readable with jq or DuckDB.
#   teley        optional (`fleet.telemetry.teley.enable`): Teley's worker
#                on 127.0.0.1:8787 for Claude's Teley MCP, fed by the same
#                collector. Off by default: wrangler dev's store grows
#                without bound and hangs under a busy app.
#
# All are host singletons on fixed ports: set `strict_ports: true` in
# devenv.yaml. When another checkout's stack already answers, the process
# attaches (idles in its slot) instead of starting a second copy, so this
# checkout's `devenv down` never stops another's stack.
#
# OpenObserve's root login is generated once into
# ~/.config/openobserve/credentials.json (mode 600) and never printed; the
# collector reads it at start. Sign in to the UI with that file's values.
#
# The OTLP env goes only to processes that merge `config.fleet.telemetry.processEnv`
# into their `env`, never into the shell, so tests stay telemetry-free.
{ pkgs, lib, config, ... }:
let
  cfg = config.fleet.telemetry;
  teley = pkgs.callPackage ../pkgs/teley.nix { };
  otelcol = pkgs.opentelemetry-collector-contrib;
  openobserve = pkgs.openobserve;
  curl = "${pkgs.curl}/bin/curl";
  jq = "${pkgs.jq}/bin/jq";
  session = "$HOME/.teley/session.json";
  creds = "$HOME/.config/openobserve/credentials.json";
  ooData = "$HOME/.local/state/openobserve";
  fileDir = "$HOME/.local/state/otelcol";

  # Teley-specific probe: a POST to an OTLP signal path gets Teley's 404 that
  # names `/r/{roomId}`. A stranger on 8787 does not pass it.
  teleyUp = "${curl} -s --max-time 2 -X POST http://127.0.0.1:${toString cfg.teley.port}/r/probe/v1/traces | grep -q 'Post OTLP to /r/'";
  # OpenObserve's health endpoint answers `{"status":"ok"}`.
  ooUp = "${curl} -s --max-time 2 http://127.0.0.1:${toString cfg.openobserve.port}/healthz | grep -q '\"ok\"'";
  # The collector's health_check extension.
  otelcolUp = "${curl} -s --max-time 2 http://127.0.0.1:${toString cfg.healthPort}/ | grep -q 'Server available'";
  attachOr = probe: name: cmd: ''
    if ${probe}; then
      echo "${name}: already running on this host; attaching"
      exec sleep infinity
    fi
    ${cmd}
  '';

  teleyEndpoint = "http://127.0.0.1:${toString cfg.teley.port}/r/@ROOM@";
  exporters = [ "otlp_http/openobserve" "file/local" ] ++ lib.optional cfg.teley.enable "otlp_http/teley";
  # JSON is YAML: the collector reads this as its config.
  config-yaml = pkgs.writeText "otelcol.yaml" (builtins.toJSON {
    extensions.health_check.endpoint = "127.0.0.1:${toString cfg.healthPort}";
    receivers.otlp.protocols.http.endpoint = "127.0.0.1:${toString cfg.otlpPort}";
    exporters = {
      "otlp_http/openobserve" = {
        endpoint = "http://127.0.0.1:${toString cfg.openobserve.port}/api/default";
        headers.Authorization = "Basic @OO_AUTH@";
        # A viewer that is restarting loses only its own copy: the file has it.
        retry_on_failure.enabled = false;
        sending_queue = { enabled = true; queue_size = 500; };
      };
      # Every signal, one JSON object per line, rotated: never blocks, never
      # grows past max_megabytes x (max_backups + 1).
      "file/local" = {
        path = "@FILE_DIR@/telemetry.jsonl";
        format = "json";
        rotation = { max_megabytes = 200; max_backups = 5; };
      };
    } // lib.optionalAttrs cfg.teley.enable {
      "otlp_http/teley" = {
        traces_endpoint = teleyEndpoint;
        logs_endpoint = teleyEndpoint;
        metrics_endpoint = teleyEndpoint;
        retry_on_failure.enabled = false;
        sending_queue = { enabled = true; queue_size = 200; };
      };
    };
    processors = {
      # A library's own spans (loro's "apply diff on", 100 000 at a song's
      # open) dropped before anything else sees them: they drown the app's.
      "filter/noise" = {
        error_mode = "ignore";
        traces.span = map (ns: "IsMatch(attributes[\"code.namespace\"], \"^${ns}\")") cfg.dropNamespaces;
      };
      # One request every two seconds, not one per span.
      batch = { timeout = "2s"; send_batch_size = 4096; };
      # The traces kept: any with an error, any of `slowMs` or more, and any
      # an app marks worth keeping whatever its length (a span attribute
      # `keep = true`, e.g. every drum-edit action). Quick clean calls (a
      # playhead poll a frame) are dropped.
      tail_sampling = {
        decision_wait = "5s";
        decision_cache.sampled_cache_size = 100000;
        policies = [
          { name = "errors"; type = "status_code"; status_code.status_codes = [ "ERROR" ]; }
          { name = "slow"; type = "latency"; latency.threshold_ms = cfg.slowMs; }
          { name = "kept"; type = "ottl_condition"; ottl_condition = { error_mode = "ignore"; span = [ "attributes[\"keep\"] == true" ]; }; }
        ];
      };
    };
    service = {
      extensions = [ "health_check" ];
      telemetry = { logs.level = "warn"; metrics.level = "none"; };
      pipelines = {
        traces = { receivers = [ "otlp" ]; processors = [ "filter/noise" "tail_sampling" "batch" ]; inherit exporters; };
        metrics = { receivers = [ "otlp" ]; processors = [ "batch" ]; inherit exporters; };
        logs = { receivers = [ "otlp" ]; processors = [ "batch" ]; inherit exporters; };
      };
    };
  });
in
{
  options.fleet.telemetry = {
    enable = lib.mkEnableOption "the local OpenObserve and OTLP collector" // { default = true; };
    otlpPort = lib.mkOption { type = lib.types.port; default = 4318; readOnly = true; };
    healthPort = lib.mkOption { type = lib.types.port; default = 13133; readOnly = true; };
    slowMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Traces at least this long (ms) are kept; shorter clean ones are dropped unless marked `keep`.";
    };
    dropNamespaces = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "loro_internal" "loro::" ];
      description = "Spans whose `code.namespace` starts with one of these are dropped (a library's own tracing).";
    };
    openobserve = {
      port = lib.mkOption { type = lib.types.port; default = 5080; readOnly = true; };
      grpcPort = lib.mkOption { type = lib.types.port; default = 5081; readOnly = true; };
      retentionDays = lib.mkOption { type = lib.types.ints.positive; default = 7; };
      package = lib.mkOption { type = lib.types.package; default = openobserve; readOnly = true; };
    };
    teley = {
      enable = lib.mkEnableOption "Teley as a second viewer (for Claude's Teley MCP)";
      port = lib.mkOption { type = lib.types.port; default = 8787; readOnly = true; };
      package = lib.mkOption {
        type = lib.types.package;
        default = teley;
        readOnly = true;
        description = "Teley's worker (pkgs/teley.nix).";
      };
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

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # OpenObserve's root login (same shape every run reads). Never printed.
      # Its password must mix cases, a digit and a symbol, or it will not start.
      tasks."fleet:openobserve-credentials" = {
        exec = ''
          f=${creds}
          [ -s "$f" ] && exit 0
          mkdir -p "$(dirname "$f")"
          umask 077
          ${jq} -n \
            --arg e "dev@openobserve.local" \
            --arg p "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)-Aa9#" \
            '{email: $e, password: $p}' > "$f"
        '';
        status = "test -s ${creds}";
        before = [ "devenv:processes:openobserve" "devenv:processes:otelcol" ];
      };

      processes.openobserve = {
        exec = attachOr ooUp "openobserve" ''
          mkdir -p ${ooData}
          export ZO_ROOT_USER_EMAIL=$(${jq} -r .email ${creds})
          export ZO_ROOT_USER_PASSWORD=$(${jq} -r .password ${creds})
          export ZO_DATA_DIR=${ooData}
          export ZO_LOCAL_MODE=true
          export ZO_HTTP_ADDR=127.0.0.1 ZO_HTTP_PORT=${toString cfg.openobserve.port}
          export ZO_GRPC_ADDR=127.0.0.1 ZO_GRPC_PORT=${toString cfg.openobserve.grpcPort}
          export ZO_COMPACT_DATA_RETENTION_DAYS=${toString cfg.openobserve.retentionDays}
          export ZO_MEMORY_CACHE_MAX_SIZE=1024 ZO_DISK_CACHE_MAX_SIZE=4096
          export ZO_TELEMETRY=false ZO_USAGE_REPORTING_ENABLED=false
          exec ${openobserve}/bin/openobserve
        '';
        ready.exec = ooUp;
      };

      processes.otelcol = {
        exec = attachOr otelcolUp "otelcol" ''
          ${lib.optionalString cfg.teley.enable ''
            room=$(${jq} -r '.roomId // empty' ${session})
            [ -n "$room" ] || { echo "otelcol: no roomId in ${session}" >&2; exit 1; }
          ''}
          auth=$(${jq} -j '.email + ":" + .password' ${creds} | base64 -w0)
          mkdir -p "$DEVENV_STATE/otelcol" ${fileDir}
          umask 077
          sed -e "s|@ROOM@|''${room:-}|g" -e "s|@OO_AUTH@|$auth|g" -e "s|@FILE_DIR@|${fileDir}|g" ${config-yaml} > "$DEVENV_STATE/otelcol/config.yaml"
          exec ${otelcol}/bin/otelcol-contrib --config "$DEVENV_STATE/otelcol/config.yaml"
        '';
        after = [ "devenv:processes:openobserve" ] ++ lib.optional cfg.teley.enable "devenv:processes:teley";
        ready.exec = otelcolUp;
      };
    }
    (lib.mkIf cfg.teley.enable {
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
    })
  ]);
}
