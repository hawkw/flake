{ config, lib, pkgs, self, ... }:

with lib;
let
  cfg = config.profiles.observability;
  cfgExporters = config.services.prometheus.exporters;
  # An attrset of all Prometheus exporters that are enabled.
  enabledExporters =
    let
      # List of exporter names that are deprecated and whose configs should not
      # be accessed.
      deprecatedExporterNames = [
        # The attribute named `unifi-poller` is deprecated in favor of
        # `unipoller`, and accessing the config for it emits a warning, so we
        # skip it to avoid that.
        "unifi-poller"
        # The `minio` exporter has been removed, so avoid touching it, since
        # accessing its attributes is an error.
        "minio"
        # The option `tor' can no longer be used since it's been removed. The
        # Tor exporter has been removed, as it was broken and unmaintained. 
        "tor"
      ];
    in
    (conf: attrsets.filterAttrs
      (name: cfg:
        # Before accessing the exporter's config, make sure it's not deprecated,
        # to avoid a warning/error for accessing it. Also, a couple of exporters
        # are lists rather than attrsets, so avoid touching those, since it
        # would be a type error to access their `enable` property.
        if !(elem name deprecatedExporterNames) && isAttrs cfg
        then cfg.enable else false)
      conf.services.prometheus.exporters);

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
        <txt-record>host=${config.networking.hostName}.local</txt-record>
      </service-group>
    '';
  mkPromExporterAvahiService = (name: mkPromAvahiService {
    inherit name;
    port = cfgExporters.${name}.port;
  });
in
{
  imports = [ ./loki.nix ];

  options.profiles.observability = with types; {
    enable = mkEnableOption "observability";
    prometheusMdns.enable = mkEnableOption "Prometheus mDNS service discovery";

    observer = {
      enable = mkEnableOption "observability collector";
      enableUnifi = mkEnableOption "Unifi poller";
      rootDomain = mkOption {
        type = str;
        default = "elizas.website";
        description = "The root domain for observability services.";
      };
      victoriametrics = {
        enable = mkOption {
          type = bool;
          default = true;
          description = "use VictoriaMetrics as the timeseries database (instead of Prometheus).";
        };
        port = mkOption {
          type = int;
          default = 8428;
          description = "VictoriaMetrics TSDB port";
        };
      };

      grafana = {
        publicDashboards = mkOption {
          type = attrsOf str;
          description = ''
            A map of URL paths to Grafana public dashboard URLs. A redirect
            for each path to the corresponding public dashboard URL will be
            added to NGINX.'';
          default = {
            "eclss" = "5c87345de11549dca71df920f8de526d";
            "eliza-ops" = "bc53c5457dbd4705bb0d56e67f57408c";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable
    (mkMerge [
      #### OBSERVEE: default prometheus exporters ####
      {
        services.prometheus.exporters = {
          node = {
            enable = mkDefault true;
            enabledCollectors = [ "systemd" "zfs" ];
            port = mkDefault 9002;
            openFirewall = mkDefault true;
          };
          # there are permissions issues with the smartctl exporter that i
          # haven't figured out yet...
          # smartctl = {
          #   enable = mkDefault true;
          #   openFirewall = mkDefault true;
          # };
          systemd = {
            enable = mkDefault true;
            openFirewall = mkDefault true;
          };
        };
      }

      #### OBSERVEE: prometheus mDNS ####
      (mkIf cfg.prometheusMdns.enable {
        # make an Avahi mDNS service for each enabled Prometheus exporter.
        services.avahi.extraServiceFiles = mkIf cfg.prometheusMdns.enable (attrsets.mapAttrs'
          (name: value: { name = "${name}-exporter"; value = mkPromExporterAvahiService name; })
          (enabledExporters config));
      })

      #### OBSERVER ############################################################
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
            appleHealthPort = 6969;

            allHostConfigs = mapAttrs (_: system: system.config) self.outputs.nixosConfigurations;
            tailscaleScrapeTargets =
              let
                mkHostExporters = (instance: config:
                  let
                    mkExporter =
                      (service: exporter: {
                        targets = [ "${instance}:${toString exporter.port}" ];
                        labels = {
                          inherit instance service;
                        };
                      });
                  in
                  mapAttrsToList mkExporter (enabledExporters config));
              in
              concatLists (mapAttrsToList mkHostExporters allHostConfigs);
            eclssScrapeTargets =
              let
                mkScrapeConfig = (instance: config: {
                  targets = [ "${instance}:${toString config.services.eclssd.server.port}" ];
                  labels = {
                    inherit instance;
                    location = "${config.services.eclssd.location}";
                  };
                });
                eclssHosts = filterAttrs (_: cfg: cfg.services.eclssd.enable) allHostConfigs;
              in
              (mapAttrsToList mkScrapeConfig eclssHosts);
            scrapeConfigs = [
              # tailscale service discovery
              {
                job_name = "tailscale";
                scrape_interval = "10s";
                scrape_timeout = "8s";
                metrics_path = "/metrics";
                scheme = "http";
                static_configs = tailscaleScrapeTargets;
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "address";
                  }
                ];
              }
              # eclss
              {
                job_name = "eclss";
                scrape_interval = "10s";
                scrape_timeout = "8s";
                metrics_path = "/metrics";
                scheme = "http";
                static_configs = eclssScrapeTargets;
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "address";
                  }
                  {
                    "if" = ''{instance=~"clavius.*"}'';
                    target_label = "location";
                    replacement = "office";
                  }
                ];
              }
              # local services
              {
                job_name = "${config.networking.hostName}";
                static_configs =
                  [
                    {
                      targets = [ "127.0.0.1:${toString cfg.loki.port}" ];
                      labels = {
                        service = "loki";
                        instance = "${config.networking.hostName}";
                      };
                    }
                  ];
              }
            ];
          in
          mkMerge [
            #### OBSERVER: defaults ####
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
              };

              # prometheus
              services.prometheus.exporters = {
                nginx = {
                  enable = config.services.nginx.enable;
                  port = mkDefault 9113;
                  scrapeUri = "http://localhost/nginx_status";
                };
                nginxlog.enable = config.services.nginx.enable;
              };

              services.docker-dashy = {
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
                    # {
                    #   name = "overview";
                    #   widgets = [
                    #     { type = "system-info"; }
                    #   ];
                    # }
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
                    {
                      name = "dashboards";
                      icon = "fas fa-monitor-heart-rate";
                      items = [
                        {
                          title = "ECLSS";
                          icon = "hl-grafana";
                          url = "https://${grafanaDomain}/eclss";
                        }
                        {
                          title = "ElizaOps";
                          icon = "hl-grafana";
                          url = "https://${grafanaDomain}/eliza-ops";
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
              # service configs for uptime-kuma that the upstream NixOS module
              # doesn't have options for
              systemd.services.uptime-kuma = {
                # add the 'docker' group so that `uptime-kuma` can monitor local
                # Docker containers' up-ness.
                serviceConfig.SupplementaryGroups = "docker";
                # add tailscale to the PATH so that the tailscale ping thingy
                # works.
                path = [ pkgs.tailscale ];
              };
            }
            #### OBSERVER: prometheus mDNS service discovery ####
            (mkIf cfg.prometheusMdns.enable {
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
                  relabel_configs = [
                    {
                      source_labels = [ "__meta_service" ];
                      target_label = "service";
                    }
                    {
                      source_labels = [ "__meta_host" ];
                      target_label = "host";
                    }
                  ];
                }
              ];
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

            #### OBSERVER: prometheus as prometheus collector (not victoriametrics) ####
            (mkIf (!cfg.observer.victoriametrics.enable) {
              services.prometheus = {
                enable = true;
                port = mkDefault 9001;
                inherit scrapeConfigs;
              };
              services.nginx.virtualHosts.${promDomain} = {
                forceSSL = true;
                useACMEHost = "home.${cfg.observer.rootDomain}";
                locations."/" = {
                  proxyPass = "http://127.0.0.1:${toString promPort}/";
                  proxyWebsockets = true;
                };
              };
              services.grafana.provision.datasources.settings.datasources = [
                {
                  name = "Prometheus";
                  type = "prometheus";
                  access = "proxy";
                  url = "http://127.0.0.1:${toString promPort}";
                }
              ];
            })
            ### nginx virtual hosts for observer services ###
            (mkIf config.profiles.nginx.enable {
              services.nginx.virtualHosts =
                let
                  forceSSL = true;
                  useACMEHost = "home.${cfg.observer.rootDomain}";
                in
                {
                  "home.${cfg.observer.rootDomain}" = {
                    locations."/" = {
                      proxyPass = "http://127.0.0.1:${toString config.services.docker-dashy.port}/";
                    };
                  };

                  ${grafanaDomain} =
                    let
                      # rewrite public dashboard URLs to shorter ones
                      redirects = mapAttrs'
                        (name: hash:
                          let
                            location = "/${name}";
                            return = "301 $scheme://${grafanaDomain}/public-dashboards/${hash}";
                          in
                          nameValuePair location {
                            inherit return;
                          })
                        cfg.observer.grafana.publicDashboards;
                      locations = redirects // {
                        "/" = {
                          proxyPass = "http://127.0.0.1:${ toString grafanaPort}/";
                          proxyWebsockets = true;
                        };
                      };
                    in
                    {
                      inherit locations forceSSL useACMEHost;
                    };


                  ${uptimeKumaDomain} = {
                    inherit forceSSL useACMEHost;
                    locations."/" = {
                      proxyPass = "http://127.0.0.1:${toString uptimeKumaPort}/";
                      proxyWebsockets = true;
                    };
                  };

                  "status.${cfg.observer.rootDomain}" = {
                    inherit forceSSL useACMEHost;
                    locations."/" = {
                      proxyPass = "http://127.0.0.1:${ toString uptimeKumaPort}/";
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
              systemd.services.promtail.serviceConfig =
                {
                  # allow promtail to read nginx logs
                  ReadOnlyPaths = [ "/var/log/nginx" ];
                };
              services.promtail.configuration.scrape_configs = [
                {
                  job_name = "nginx";
                  static_configs = [{
                    targets = [ "localhost" ];
                    labels = {
                      __path__ = "/var/log/nginx/*log";
                      host = config.networking.hostName;
                      job = "nginx";
                    };
                  }];
                  pipeline_stages = [{
                    match = {
                      selector = ''{job="nginx"}'';
                      stages = [
                        {
                          regex.expression = ''^(?P<remote_addr>[\w\.]+) - (?P<remote_user>[^ ]*) \[(?P<time_local>.*)\] "(?P<method>[^ ]*) (?P<request>[^ ]*) (?P<protocol>[^ ]*)" (?P<status>[\d]+) (?P<body_bytes_sent>[\d]+) "(?P<http_referer>[^\"]*)\" "(?P<http_user_agent>[^"]*)'';
                        }
                        {
                          labels = {
                            remote_addr = "remote_addr";
                            remote_user = "remote_user";
                            time_local = "time_local";
                            method = "method";
                            request = "request";
                            protocol = "protocol";
                            status = "status";
                            body_bytes_sent = "body_bytes_sent";
                            http_referer = "http_referer";
                            http_user_agent = "http_user_agent";
                          };
                        }
                      ];
                    };
                  }];
                }
              ];
            })

            (mkIf cfg.observer.victoriametrics.enable (
              let
                grafanaDataource = "victoriametrics-datasource";
                port = cfg.observer.victoriametrics.port;
              in
              {
                # VictoriaMetrics
                services.victoriametrics = {
                  enable = true;
                  listenAddress = ":${toString port}";
                  extraOptions =
                    let
                      scrapeConfigFile = (pkgs.formats.yaml { }).generate "prom-scrape-config.yml" {
                        scrape_configs = scrapeConfigs;
                      };
                    in
                    [
                      # required for victoriametrics to parse the config
                      "-promscrape.config.strictParse=false"
                      "-promscrape.config=${scrapeConfigFile}"
                      # rename influxdb metrics names to not be malformed in
                      # prometheus
                      # e.g. change `/` to `_`, etc
                      "-usePromCompatibleNaming=true"
                    ];
                };

                # add VictoriaMetrics datasource to Grafana.
                services.grafana = {
                  settings.plugins = {
                    # see https://docs.victoriametrics.com/grafana-datasource/#why-victoriametrics-datasource-is-unsigned
                    allow_loading_unsigned_plugins = grafanaDataource;
                  };
                  provision.datasources.settings.datasources = [{
                    name = "VictoriaMetrics";
                    type = grafanaDataource;
                    access = "proxy";
                    url = "http://127.0.0.1:${toString port}";
                  }
                    # TODO until the VictoriaMetrics datasource works
                    {
                      name = "VictoriaMetrics Prometheus";
                      type = "prometheus";
                      access = "proxy";
                      url = "http://127.0.0.1:${toString port}";
                    }];
                };


                virtualisation.oci-containers.containers = let hostDnsName = "host.docker.internal"; in {
                  apple-health-ingester = {
                    image = "irvinlim/apple-health-ingester:v0.4.0";
                    cmd = [
                      "--log=debug"
                      "--backend.influxdb"
                      "--influxdb.serverURL=http://${hostDnsName}:${toString port}"
                      "--influxdb.orgName=eliza-networks"
                      "--influxdb.metricsBucketName=apple_health_metrics"
                      "--influxdb.workoutsBucketName=apple_health_workouts"
                      "--http.listenAddr=:${toString appleHealthPort}"
                      #                 ngester \
                      # --backend.influxdb \
                      # --influxdb.serverURL=http://localhost:8086 \
                      # --influxdb.authToken=INFLUX_API_TOKEN \
                      # --influxdb.orgName=my-org \
                      # --influxdb.metricsBucketName=apple_health_metrics \
                      # --influxdb.workoutsBucketName=apple_health_workouts
                    ];
                    environment = {
                      TZ = "${config.time.timeZone}";
                    };
                    ports = [
                      "${toString appleHealthPort}:${toString appleHealthPort}"
                    ];
                    extraOptions = [
                      "--add-host=${hostDnsName}:host-gateway"
                    ];
                  };
                };
              }
            ))
            (mkIf cfg.observer.enableUnifi {
              services.prometheus.exporters.unpoller = {
                enable = true;
                log.prometheusErrors = true;
                loki = {
                  url = "http://127.0.0.1:${toString cfg.loki.port}";
                };
                controllers = [{
                  user = "readonly2";
                  pass = /etc/secrets/unpoller-dream-machine.password;
                  # Per the Unpoller docs:
                  # > When configuring make sure that you do not include :8443
                  # > on the url of the controller if you are using unifios.
                  # > Those are: UDM Pro, UDM, UXG, or CloudKey with recent
                  # > firmware.
                  url = "https://unifi";
                  verify_ssl = false;
                  save_events = true;
                  save_anomalies = true;
                  save_alarms = true;
                  save_dpi = false;
                  save_sites = true;
                  save_ids = false;
                }];
              };
            })
          ]
        ))
    ]);
}
