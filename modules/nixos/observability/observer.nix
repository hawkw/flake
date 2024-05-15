{ config, lib, pkgs, ... }:

with lib;
let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability.observer;
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

  config = mkIf cfg.enable (mkMerge [
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
  ]);
}
