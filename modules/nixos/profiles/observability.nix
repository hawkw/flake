{ config, lib, pkgs, ... }:

with lib;
let
  mdnsJson = "/etc/prometheus/mdns-sd.json";
  cfg = config.profiles.observability;
  cfgExporters = config.services.prometheus.exporters;
  # An attrset of all Prometheus exporters that are enabled.
  enabledExporters = attrsets.filterAttrs
    (_: cfg: if isAttrs cfg then cfg.enable else false)
    cfgExporters;

  mkAvahiService = { name, port, type }:
    ''
      <?xml version="1.0" standalone='no'?>
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">${name} on %h</name>
        <service>
          <type>${type}</type>
          <port>${toString port}</port>
        </service>
      </service-group>
    '';
  mkPromExporterAvahiService = (name: mkAvahiService {
    name = "Prometheus ${name}-exporter";
    type = "_prometheus-http._tcp";
    port = cfgExporters.${name}.port;
  });
in
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
          enable = mkDefault true;
          enabledCollectors = [ "systemd" "zfs" ];
          port = mkDefault 9002;
          openFirewall = mkDefault true;
        };
        smartctl = {
          enable = mkDefault true;
          openFirewall = mkDefault true;
        };
      };

      # make an Avahi mDNS service for each enabled Prometheus exporter.
      services.avahi.extraServiceFiles = attrsets.mapAttrs'
        (name: value: { name = "${name}-exporter"; value = mkPromExporterAvahiService name; })
        enabledExporters;
    })

    (mkIf
      cfg.observer
      (
        let
          grafanaPort = config.services.grafana.settings.server.http_port;
          grafanaDomain = config.services.grafana.settings.server.domain;
          promDomain = "prometheus.elizas.website";
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

          services.dashy = {
            enable = true;
            settings = {
              pageInfo = {
                title = "home.elizas.website";
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
                  ];
                }
              ];

            };
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
          networking.firewall.allowedTCPPorts =
            [ 80 443 ];

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
              serverAliases = [ grafanaDomain promDomain ];
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString config.services.dashy.port}/";
              };
            };

            virtualHosts.${grafanaDomain} = {
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

            virtualHosts.${promDomain} = {
              forceSSL = true;
              useACMEHost = "home.elizas.website";
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
            };
          };
        }
      ))
  ];

}
