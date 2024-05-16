{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.profiles.observability;
  cfgExporters = config.services.prometheus.exporters;
  # An attrset of all Prometheus exporters that are enabled.
  enabledExporters = attrsets.filterAttrs
    (name: cfg:
      if
      # The attribute named `unifi-poller` is deprecated in favor of
      # `unipoller`, and accessing the config for it emits a warning, so we
      # skip it to avoid that.
        name != "unifi-poller" &&
        # A couple of exporters are lists rather than attrsets, so avoid
        # touching those, since it would be a type error.
        isAttrs cfg
      then cfg.enable else false)
    cfgExporters;

  mkPromAvahiService = { name, port }:
    ''
      <?xml version="1.0" standalone='no'?>
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">Prometheus ${name}-exporter on %h</name>
        <service protocol="any">
          <type>_prometheus-http._tcp</type>
          <port>${toString port}</port>
        </service>
        <txt-record>service=${name}</txt-record>
      </service-group>
    '';
  mkPromExporterAvahiService = (name: mkPromAvahiService {
    inherit name;
    port = cfgExporters.${name}.port;
  });
in
{

  options.profiles.observability = {
    enable = mkEnableOption "observability";

    loki = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the Loki log aggregation service.";
      };
      port = mkOption {
        type = types.int;
        default = 3100;
        description = "The port to run the Loki service on.";
      };

      promtailPort = mkOption {
        type = types.int;
        default = 28183;
        description = "The port to run the Promtail service on.";
      };
    };

    observer = {
      enable = mkEnableOption "observability collector";
      rootDomain = mkOption {
        type = types.str;
        default = "elizas.website";
        description = "The root domain for observability services.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [{
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
      systemd = {
        enable = mkDefault true;
        openFirewall = mkDefault true;
      };
    };

    # make an Avahi mDNS service for each enabled Prometheus exporter.
    services.avahi.extraServiceFiles = attrsets.mapAttrs'
      (name: value: { name = "${name}-exporter"; value = mkPromExporterAvahiService name; })
      enabledExporters;
  }

    (mkIf cfg.loki.enable {
      services.promtail = {
        enable = true;
        configuration = {
          server = {
            http_listen_port = cfg.loki.promtailPort;
            grpc_listen_port = 0;
          };

          clients = mkDefault [{
            url = "http://noctis.local:${toString cfg.loki.port}/loki/api/v1/push";
          }];

          scrape_configs = [
            {
              job_name = "journal";
              journal = {
                max_age = "12h";
                json = true;
                labels = {
                  job = "systemd-journal";
                  host = "${config.networking.hostName}";
                };
              };

              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "unit";
                }
                {
                  source_labels = [ "__journal_priority_keyword" ];
                  target_label = "level";
                }
                {
                  source_labels = [ "__journal_syslog_identifier" ];
                  target_label = "syslog_identifier";
                }
              ];

              pipeline_stages = [
                # drop logs emitted by promtail itself.
                {
                  match = {
                    selector = ''{unit="promtail.service"}'';
                    action = "drop";
                  };
                }
              ];
            }
          ];
        };
      };

      # make an Avahi mDNS service for the Promtail metrics endpoint
      services.avahi.extraServiceFiles.promtail-metrics = mkPromAvahiService
        {
          name = "promtail";
          port = cfg.loki.promtailPort;
        };

      networking.firewall.allowedTCPPorts = [ cfg.loki.promtailPort ];
    })

    (mkIf cfg.observer.enable
      (
        let
          mdnsJson = "/etc/prometheus/mdns-sd.json";
          grafanaPort = config.services.grafana.settings.server.http_port;
          grafanaDomain = config.services.grafana.settings.server.domain;
          promDomain = "prometheus.${cfg.observer.rootDomain}";
          promPort = config.services.prometheus.port;
          uptimeKumaPort = 3001;
          uptimeKumaDomain = "uptime.${cfg.observer.rootDomain}";
        in
        mkMerge [
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
                  relabel_configs = [{
                    source_labels = [ "__meta_service" ];
                    target_label = "service";
                  }];
                }
                # local services
                {
                  job_name = "${config.networking.hostName}";
                  static_configs = (attrsets.mapAttrsToList
                    (name: exporter: {
                      targets = [ "127.0.0.1:${toString exporter.port}" ];
                      labels = {
                        service = "${name}";
                      };
                    })
                    enabledExporters) ++ [
                    {
                      targets = [ "127.0.0.1:${toString cfg.loki.port}" ];
                      labels = { service = "loki"; };
                    }
                  ];
                }
                # # tailscale dns
                # {
                #   job_name = "tailscale";
                #   scrape_interval = "10s";
                #   scrape_timeout = "8s";
                #   metrics_path = "/metrics";
                #   scheme = "http";
                #   http_sd_configs = (attrsets.mapAttrsToList
                #     (name: exporter: {
                #       targets = [ "theseus:${toString exporter.port}" ];
                #       labels = {
                #         service = "${name}";
                #         instance = "theseus";
                #       };
                #     })
                #     enabledExporters);
                # }
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

            services.promtail.configuration.scrape_configs = [
              {
                job_name = "nginx";
                static_configs = {
                  targets = [ "localhost" ];
                  labels = {
                    __path__ = "/var/log/nginx/*.log";
                    host = config.networking.hostName;
                    job = "nginx";
                  };
                };
                pipeline_stages = [{
                  match = {
                    selector = ''{__path__="/var/log/nginx/access.log"}'';
                    stages = [
                      {
                        regex.expression = ''^(?P<remote_addr>[\w\.]+) - (?P<remote_user>[^ ]*) \[(?P<time_local>.*)\] "(?P<method>[^ ]*) (?P<request>[^ ]*) (?P<protocol>[^ ]*)" (?P<status>[\d]+) (?P<body_bytes_sent>[\d]+) "(?P<http_referer>[^"]*)" "(?P<http_user_agent>[^"]*)'';
                      }
                      {
                        labels = {
                          remote_addr = { };
                          remote_user = { };
                          time_local = { };
                          method = { };
                          request = { };
                          protocol = { };
                          status = { };
                          body_bytes_sent = { };
                          http_referer = { };
                          http_user_agent = { };
                        };
                      }
                    ];
                  };
                }];
              }
            ];
          })

          (mkIf cfg.loki.enable (
            let dataDir = config.services.loki.dataDir; in {

              networking.firewall.allowedTCPPorts = [ cfg.loki.port ];

              services.grafana.provision.datasources.settings.datasources = [
                {
                  name = "Loki";
                  type = "loki";
                  access = "proxy";
                  url = "http://127.0.0.1:${toString cfg.loki.port}";
                }
              ];

              services.promtail.configuration.clients = mkForce [{
                url = "http://localhost:${toString cfg.loki.port}/loki/api/v1/push";
              }];

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
                  #   retention_period = "0s";
                  # };
                };
              };
            }
          ))
        ]
      ))]);
}
