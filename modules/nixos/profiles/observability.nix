{ config, lib, pkgs, ... }:

let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability;
  nodeExporterPort = config.services.prometheus.exporters.node.port;
in
with lib;
{
  options.profiles.observability = {
    enable = mkEnableOption "observability";
    observer = mkEnableOption "observability collector";
  };

  config = mkMerge [
    { }
    (mkIf cfg.enable {
      services.prometheus.exporters = {
        node = {
          enable = true;
          enabledCollectors = [ "systemd" "zfs" ];
          port = mkDefault 9002;
          openFirewall = mkDefault true;
        };
      };
      services.avahi.extraServiceFiles.node-exporter =
        ''<?xml version = "1.0" standalone='no'?><!--*-nxml-*-->
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">

<service-group>
  <name replace-wildcards="yes">node-exporter on %h</name>
  <service>
    <type>_prometheus-http._tcp</type>
    <port>${toString nodeExporterPort}</port>
  </service>
</service-group>'';
    })
    (mkIf
      cfg.observer
      (
        let
          grafanaPort = config.services.grafana.port;
          promPort = config.services.prometheus.port;
        in
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
                domain = "grafana.elizas.website";
                serve_from_sub_path = true;
                http_port = mkDefault 9094;
                http_addr = "127.0.0.1";
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
                  targets = [
                    "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
                    "127.0.0.1:${toString config.services.prometheus.exporters.nginx.port}"
                    "127.0.0.1:${toString config.services.prometheus.exporters.nginxlog.port}"
                  ];
                }];

              }
            ];
            exporters = {
              nginx = {
                enable = true;
                port = 9113;
                scrapeUri = "http://localhost/nginx_status";
              };
              nginxlog.enable = true;
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

          services.avahi.extraServiceFiles = {
            nginx =
              ''<?xml version = "1.0" standalone='no'?><!--*-nxml-*-->
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">

<service-group>
  <name replace-wildcards="yes">nginx on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
  </service>
    <service>
      <type>_https._tcp</type>
      <port>443</port>
  </service>
</service-group>'';
          };

          # open firewall ports
          networking.firewall.allowedTCPPorts = [ 80 443 ];

          # nginx reverse proxy config to expose grafana
          security.acme.acceptTerms = true;
          security.acme.defaults.email = "eliza@elizas.website";
          services.nginx = {
            enable = true;
            statusPage = true;

            # Use recommended settings
            recommendedGzipSettings = true;
            recommendedOptimisation = true;
            recommendedProxySettings = true;
            recommendedTlsSettings = true;

            virtualHosts."home.elizas.website" = {
              forceSSL = true;
              enableACME = true;
              serverAliases = [ config.services.grafana.domain "prometheus.elizas.website" ];
              locations."/" = {
                root = "/var/www";
              };
            };

            virtualHosts.${config.services.grafana.domain} = {
              forceSSL = true;
              useACMEHost = "home.elizas.website";
              locations."/" = {
                root = "/var/www";
              };
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString grafanaPort}/";
                proxyWebsockets = true;
                # extraConfig = "proxy_redirect default;";
              };
            };

            virtualHosts."prometheus.elizas.website" = {
              forceSSL = true;
              useACMEHost = "home.elizas.website";
              locations."/" = {
                root = "/var/www";
              };
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString promPort}/";
                proxyWebsockets = true;
                # extraConfig = "proxy_redirect default;";
              };
            };

            virtualHosts."${config.networking.hostName}.local" = {
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
              locations."/metrics/" = {
                proxyPass = "http://127.0.0.1:${toString nodeExporterPort}/";
                proxyWebsockets = true;
                extraConfig = "proxy_redirect default;";
              };
            };
          };
        }
      ))
  ];

}
