{ config, lib, pkgs, ... }:

with lib;
let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability;
  grafanaPort = config.services.grafana.settings.server.http_port;
  grafanaDomain = config.services.grafana.settings.server.domain;
  promDomain = "prometheus.${cfg.observer.rootDomain}";
  promPort = config.services.prometheus.port;
  uptimeKumaPort = 3001;
  uptimeKumaDomain = "uptime.${cfg.rootDomain}";
in
{
  options.profiles.observability.observer = {
    enable = mkEnableOption "observability collector";
    rootDomain = mkOption {
      type = types.str;
      default = "elizas.website";
      description = "The root domain for observability services.";
    };
  };

  config = mkIf cfg.observer.enable (mkMerge [
    {
      environment.systemPackages = with pkgs;
        [ prometheusMdns ];

      # grafana
      services.grafana = {
        enable = true;
        settings = {
          # auth.disable_login_form = true;
          "auth.anonymous".enable = true;
          "auth.anonymous".enabled = true;
          "auth.anonymous".org_name = "randos";
          "auth.anonymous".org_role = "Viewer";

          server = {
            domain = "grafana.${cfg.observer.rootDomain}";
            serve_from_sub_path = true;
            http_port = mkDefault 9094;
            http_addr = "127.0.0.1";
          };
          security = {
            admin_user = "admin";
            admin_password = "admin";
          };
        };
        provision.datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString promPort}";
          }
        ];
      };

      # prometheus
      services.prometheus = {
        enable = true;
        port = mkDefault 9001;
        scrapeConfigs = [
          # mDNS service discovery
          {
            job_name = "mdns-sd";
            scrape_interval = "10s";
            scrape_timeout = "8s";
            metrics_path = "/metrics";
            scheme = "http";
            file_sd_configs = [{
              files = [ mdnsJson ];
              refresh_interval = "5m";
            }];
          }
          {
            job_name = "${config.networking.hostName}";
            static_configs = [{
              targets = attrsets.mapAttrsToList
                (_: exporter: "127.0.0.1:${toString exporter.port}")
                enabledExporters;
            }];

          }
        ];
        exporters = {
          nginx = {
            enable = config.services.nginx.enable;
            port = mkDefault 9113;
            scrapeUri = "http://localhost/nginx_status";
          };
          nginxlog.enable = config.services.nginx.enable;
        };
      };

      systemd.services.prometheus-mdns = {
        enable = true;
        description = "Prometheus mDNS service discovery";
        unitConfig = { Type = "simple"; };
        # prometheus will warn if the scrape target file is missing, so ensure this
        # service starts first.
        before = [ "prometheus.service" ];
        serviceConfig = {
          ExecStart = ''
            ${pkgs.prometheusMdns}/bin/prometheus-mdns-sd -out ${mdnsJson}
          '';
          Restart = "always";
        };
        wantedBy = [ "multi-user.target" ];
      };

      services.dashy = {
        enable = true;
        settings = {
          pageInfo = {
            title = "home.${cfg.observer.rootDomain}";
          };
          appConfig = {
            # theme = "nord-frost";
            layout = "auto";
            iconSize = "medium";
            language = "en";
            statusCheck = true;
            hideComponents.hideSettings = false;
          };
          sections = [
            {
              name = "overview";
              widgets = [
                { type = "system-info"; }
              ];
            }
            {
              name = "monitoring";
              icon = "fas fa-monitor-heart-rate";
              items = [
                {
                  title = "Grafana";
                  icon = "hl-grafana";
                  url = "https://${grafanaDomain}";
                }
                {
                  title = "Prometheus";
                  icon = "hl-prometheus";
                  url = "https://${promDomain}";
                }
                {
                  title = "Uptime Kuma";
                  icon = "hl-uptime-kuma";
                  url = "https://${uptimeKumaDomain}";
                }
              ];
            }
          ];

        };
      };

      services.uptime-kuma = {
        enable = true;
        settings = {
          PORT = toString uptimeKumaPort;
        };
      };
    }

    ### nginx virtual hosts for observer services ###
    (mkIf config.profiles.nginx.enable {
      services.nginx.virtualHosts = {
        "home.${cfg.observer.rootDomain}" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.dashy.port}/";
          };
        };

        ${grafanaDomain} = {
          forceSSL = true;
          useACMEHost = "home.${cfg.observer.rootDomain}";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString grafanaPort}/";
            proxyWebsockets = true;

          };
        };

        ${promDomain} = {
          forceSSL = true;
          useACMEHost = "home.${cfg.observer.rootDomain}";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString promPort}/";
            proxyWebsockets = true;
          };
        };

        ${uptimeKumaDomain} = {
          forceSSL = true;
          useACMEHost = "home.${cfg.observer.rootDomain}";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString uptimeKumaPort}/";
            proxyWebsockets = true;
          };
        };

        "status.${cfg.observer.rootDomain}" = {
          forceSSL = true;
          useACMEHost = "home.${cfg.observer.rootDomain}";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString uptimeKumaPort}/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_set_header Host status.${cfg.observer.rootDomain};
              proxy_set_header X-Forwarded-Host status.${cfg.observer.rootDomain};
            '';
          };
        };

        "${config.networking.hostName}.local" = {
          locations."/grafana/" = {
            proxyPass = "http://127.0.0.1:${toString grafanaPort}/";
            proxyWebsockets = true;
            extraConfig = "proxy_redirect default;";
          };
          locations."/prometheus/" = {
            proxyPass = "http://127.0.0.1:${toString promPort}/";
            proxyWebsockets = true;
            extraConfig = "proxy_redirect default;";
          };
        };
      };
    })

    (mkIf.loki.enable (
      let dataDir = config.services.loki.dataDir; in {
        networking.firewall.allowedTCPPorts = [ config.observability.loki.port ];
        services.loki = {
          enable = true;
          dataDir = mkDefault "/var/lib/loki";
          configuration = {
            # TODO(eliza): auth?
            auth_enabled = false;
            server = {
              http_listen_port = cfg.loki.port;
            };
            ingester = {
              lifecycler = {
                address = "0.0.0.0";
                ring = {
                  kvstore.store = "inmemory";
                  replication_factor = 1;
                };
                final_sleep = "0s";
              };
              # Any chunk not receiving new logs in this time will be flushed
              chunk_idle_period = "1h";
              # All chunks will be flushed when they hit this age, default is 1h
              max_chunk_age = "1h";
              # Loki will attempt to build chunks up to 1.5MB, flushing first if
              # chunk_idle_period or max_chunk_age is reached first
              chunk_target_size = 1048576;
              # Must be greater than index read cache TTL if using an index cache
              # (Default index read cache TTL is 5m)
              chunk_retain_period = "30s";
              # Chunk transfers disabled
              max_transfer_retries = 0;
            };

            storage_config = {
              boltdb_shipper = {
                active_index_directory = "${dataDir}/boltdb-shipper-active";
                cache_location = "${dataDir}/boltdb-shipper-cache";
                # Can be increased for faster performance over longer query
                # periods, uses more disk space
                cache_ttl = "24h";
              };
              filesystem = {
                directory = "${dataDir}/chunks";
              };
            };

            limits_config = {
              reject_old_samples = true;
              reject_old_samples_max_age = "168h";
            };

            chunk_store_config = {
              max_look_back_period = "0s";
            };

            table_manager = {
              retention_deletes_enabled = false;
              retention_period = "0s";
            };
          };
        };
      }
    ))
  ]);
}
