{ config, lib, ... }:

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
  imports = [ "./observer.nix" ];

  options.profiles.observability = {
    enable = mkEnableOption "observability";
  };

  config = mkIf cfg.enable {
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
  };
}
