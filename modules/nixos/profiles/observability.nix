{ config, lib, pkgs, ... }:

let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability;
in
{
  options.profiles.observability = with lib; {
    enable = mkEnableOption "observability profile";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ prometheusMdns ];

    # grafana
    services.grafana = {
      enable = true;
      settings = {
        server = {
          domain = "grafana.local";
          http_port = 9094;
          http_addr = "0.0.0.0";
        };
        security = {
          admin_user = "admin";
          admin_password = "admin";
        };
      };
    };

    # prometheus
    services.prometheus = {
      enable = true;
      port = 9001;
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
        # local node exporter
        {
          job_name = "${config.networking.hostName}";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
          }];
        }
      ];

      exporters = {
        node = {
          enable = true;
          enabledCollectors = ["systemd"];
          port = 9002;
        };
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

    # nginx reverse proxy config to expose grafana
    services.nginx.virtualHosts.${config.services.grafana.domain} = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.grafana.port}";
        proxyWebsockets = true;
      };
    };
  };

}
