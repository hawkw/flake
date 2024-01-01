{ config, lib, pkgs, ... }:

let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability;
  grafanaPath = "grafana";
  grafanaCfg = config.services.grafana;
  promPath = "prometheus";
  promCfg = config.services.prometheus;
in
{
  options.profiles.observability = with lib; {
    enable = lib.mkEnableOption "observability profile";
    domain = mkOption {
      type = types.str;
      default = "home.elizas.website";
    };
    prometheus = {
      enableMdns = mkOption {
        type = types.bool;
        default = true;
        description = "enable mDNS service discovery";
      };
    };
  };

  config = with lib;
    mkMerge [
      { }

      # grafana
      (mkIf (cfg.enable) {
        services.grafana = {
          enable = true;
          settings = {
            server = {
              # Listening Address
              http_addr = lib.mkDefault "127.0.0.1";
              # and Port
              http_port = lib.mkDefault 3000;
              # Grafana needs to know on which domain and URL it's running
              domain = cfg.domain;
              root_url = "https://${cfg.domain}/${grafanaPath}/";
            };
            security = {
              admin_user = lib.mkDefault "admin";
              admin_password = lib.mkDefault "admin";
            };
          };
        };
        services.prometheus = let nodePort = toString promCfg.exporters.node.port; in {
          enable = true;
          webExternalUrl = "https://${cfg.domain}/${promPath}/";
          exporters = {
            node = {
              enable = true;
              port = lib.mkDefault 9100;
              enabledCollectors = [ "logind" "systemd" ];
              disabledCollectors = [ "textfile" ];
              openFirewall = true;
              firewallFilter = "-i br0 -p tcp -m tcp --dport ${nodePort}";
            };
            unifi = {
              enable = true;
              unifiAddress = "https://192.168.0.1/";
              unifiUsername = "readonly";
              unifiPassword = "ReadonlyUser1";
            };
          };
          scrapeConfigs = [
            {
              job_name = "node";
              static_configs = [{
                targets =
                  [ "localhost:${nodePort}" ];
              }];
            }
            {
              job_name = "unifi";
              static_configs = [{
                targets =
                  [ "localhost:${toString promCfg.exporters.unifi.port}" ];
              }];
            }
          ];
        };
        # nginx reverse proxy config
        services.nginx.virtualHosts.${cfg.domain} = {
          addSSL = true;
          enableACME = true;
          locations."/${grafanaPath}" = {
            proxyPass =
              "http://${toString grafanaCfg.settings.server.http_addr}:${
                toString grafanaCfg.port
              }";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };

          locations."/${promPath}" = {
            proxyPass = "http://${toString promCfg.listenAddress}:${
                toString promCfg.port
              }";
            recommendedProxySettings = true;
          };
        };

      })

      (mkIf (cfg.enable && cfg.prometheus.enableMdns) {
        services.prometheus.scrapeConfigs = [
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
        ];

        environment.systemPackages = with pkgs; [ prometheusMdns ];

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
      })
    ];
}
