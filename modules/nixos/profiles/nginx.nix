{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.nginx;
in
{
  options.profiles.nginx = {
    enable = mkEnableOption "NGINX reverse proxy profile";
    domain = mkOption {
      type = types.str;
      default = "elizas.website";
      description = "The root domain for NGINX services.";
    };
    acmeSubdomain = mkOption {
      type = types.nullOr types.str;
      default = "home.${cfg.observer.rootDomain}";
      description = "The subdomain to use for the ACME certificate, if any";
    };
  };

  config = mkIf cfg.enable
    (
      let
        acmeDomain =
          if isNull cfg.acmeSubdomain
          then cfg.domain
          else "${cfg.acmeSubdomain}.${cfg.domain}";
      in
      {

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

        # nginx reverse proxy config
        security.acme = {
          acceptTerms = true;
          defaults.email = lib.mkDefault "acme@elizas.website";
          certs.${acmeDomain} = {
            domain = "${acmeDomain}";
            extraDomainNames = trivial.pipe config.services.nginx.virtualHosts [
              # include any configured NGINX virtual host that's configured to
              # use the root domain ACME host.
              (attrsets.filterAttrs
                (_: attrsets.matchAttrs { useACMEHost = "${acmeDomain}"; }))
              # just get the names of the virtual hosts.
              attrNames
            ];
          };
        };
        services.nginx = {
          enable = true;
          statusPage = true;

          # Use recommended settings
          recommendedGzipSettings = true;
          recommendedOptimisation = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;


          virtualHosts."${acmeDomain}" = {
            forceSSL = true;
            enableACME = true;
          };
        };
      }
    );
}
