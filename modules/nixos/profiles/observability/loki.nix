{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.observability;

  # Generate the Alloy configuration for journal log scraping.
  #
  # The pipeline is:
  #   loki.source.journal -> loki.process (drop alloy's own logs) -> loki.write
  #
  # The relabel rules extract the systemd unit, priority keyword, and syslog
  # identifier from journal entries.
  mkAlloyConfig = lokiUrl: ''
    loki.write "default" {
      endpoint {
        url = "${lokiUrl}"
      }
    }

    // --- Journal relabeling rules ---
    // Extract systemd unit, priority, and syslog identifier from journal
    // fields.
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
      rule {
        source_labels = ["__journal_syslog_identifier"]
        target_label  = "syslog_identifier"
      }
    }

    // --- Drop Alloy's own logs ---
      forward_to = [loki.write.default.receiver]

      stage.match {
        selector = "{unit=\"alloy.service\"}"
        action   = "drop"
      }
    }

    // --- Journal source ---
    loki.source.journal "read" {
      forward_to     = [loki.process.journal.receiver]
      relabel_rules  = loki.relabel.journal.rules
      max_age        = "12h"
      format_as_json = true
      labels         = {
        job  = "systemd-journal",
        host = "${config.networking.hostName}",
      }
    }
  '';
in
{
  options.profiles.observability.loki = with types; {
    enable = mkOption {
      type = bool;
      default = true;
      description = "Enable the Loki log aggregation service.";
    };
    port = mkOption {
      type = int;
      default = 3100;
      description = "The port to run the Loki service on.";
    };

    alloyPort = mkOption {
      type = int;
      default = 28183;
      description = "The port to run the Alloy HTTP server on.";
    };
  };

  config = mkMerge [
    #### OBSERVEE: Alloy log shipper ####
    (mkIf cfg.loki.enable {
      services.alloy = {
        enable = true;
        extraFlags = [
          "--server.http.listen-addr=127.0.0.1:${toString cfg.loki.alloyPort}"
          "--disable-reporting"
        ];
      };

      environment.etc."alloy/config.alloy".text = mkDefault
        (mkAlloyConfig "http://tereshkova.sys.home.elizas.website:${toString cfg.loki.port}/loki/api/v1/push");
    })

    #### OBSERVER: Loki server ####
    (mkIf (cfg.loki.enable && cfg.observer.enable) (
      let dataDir = config.services.loki.dataDir;
      in {

        networking.firewall.allowedTCPPorts = [ cfg.loki.port ];

        services.grafana.provision.datasources.settings.datasources = [
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString cfg.loki.port}";
          }
        ];

        # On the observer node, point Alloy at the local Loki instance
        # instead of the default remote URL.
        environment.etc."alloy/config.alloy".text = mkForce
          (mkAlloyConfig "http://localhost:${toString cfg.loki.port}/loki/api/v1/push");

        #### OBSERVER: Loki ####
        services.loki = {
          enable = true;
          dataDir = mkDefault "/var/lib/loki";
          configuration = {
            # TODO(eliza): auth?
            auth_enabled = false;
            server.http_listen_port = cfg.loki.port;

            common = {
              ring = {
                instance_addr = "0.0.0.0";
                kvstore.store = "inmemory";
              };
              replication_factor = 1;
              path_prefix = dataDir;
            };

            # ingester = {
            #   # Any chunk not receiving new logs in this time will be flushed
            #   chunk_idle_period = "1h";
            #   # All chunks will be flushed when they hit this age, default is 1h
            #   max_chunk_age = "1h";
            #   # Loki will attempt to build chunks up to 1.5MB, flushing first if
            #   # chunk_idle_period or max_chunk_age is reached first
            #   chunk_target_size = 1048576;
            #   # Must be greater than index read cache TTL if using an index cache
            #   # (Default index read cache TTL is 5m)
            #   chunk_retain_period = "30s";
            #   # # Chunk transfers disabled
            #   # max_transfer_retries = 0;
            # };

            schema_config.configs = [
              {
                from = "2020-01-01";
                store = "tsdb";
                object_store = "filesystem";
                schema = "v13";
                index = {
                  prefix = "index_";
                  period = "24h";
                };
              }
            ];

            storage_config = {
              # boltdb_shipper = {
              #   active_index_directory = "${dataDir}/boltdb-shipper-active";
              #   cache_location = "${dataDir}/boltdb-shipper-cache";
              #   # Can be increased for faster performance over longer query
              #   # periods, uses more disk space
              #   cache_ttl = "24h";
              # };
              filesystem = {
                directory = "${dataDir}/chunks";
              };
            };

            # limits_config = {
            #   reject_old_samples = true;
            #   reject_old_samples_max_age = "168h";
            # };

            # chunk_store_config = {
            #   max_look_back_period = "0s";
            # };

            # table_manager = {
            #   retention_deletes_enabled = false;
            #   retention_period = "0s" ;
            # };
          };
        };
      }
    ))
  ];
}
