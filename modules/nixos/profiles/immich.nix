# Configuration for immich
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.immich;
in
{
  options.profiles.immich = {
    enable = mkEnableOption "immich";
    domain = mkOption {
      type = types.str;
      default = "photos.home.elizas.website";
    };
  };

  config = mkIf cfg.enable
    (mkMerge [
      {
        services.immich = {
          enable = true;

          # This is enabled by default, but included here for explicitness. By
          # default, the immich nixos module creates its own database and role
          # on the system PostgreSQL instance. Immich connects to the database
          # over a Unix socket using postgres peer authentication (the OS user
          # `immich` maps to the postgres role `immich`).
          database.enable = true;
        };

        # By default, `local all all peer` lets every local role connect to
        # every database. Roles can't read other roles' tables, but they can
        # enumerate catalogs and create temporary tables. There's no real reason
        # for immich to do this, and it's exposed to the network, so the
        # principle of least priveliege suggests we should restrict its role to
        # only its own database.
        #
        # These lines are inserted above the default rules, and pg_hba stops at
        # the first match. This is additive rather than replacing the defaults
        # with `mkForce`, which would silently drop other modules' rules.
        services.postgresql.authentication =
          let inherit (config.services.immich.database) name user; in
          mkIf config.services.immich.database.enable ''
            local ${name} ${user} peer
            local all ${user} reject
          '';

        environment.systemPackages = with pkgs; [
          immich-cli # let's also include the CLI
        ];
      }
      # if caddy is enabled, use it to reverse proxy to immich
      (mkIf config.services.caddy.enable {
        services.caddy.virtualHosts."${cfg.domain}" =
          let
            inherit (config.services.immich) port;
          in
          {
            useACMEHost = "home.elizas.website";
            extraConfig = ''
              reverse_proxy http://[::1]:${toString port} {
                header_up Host {http.reverse_proxy.header.Host}
                header_up X-Real-IP {http.request.remote.host}
                header_up X-Forwarded-For {http.request.remote.host}
                header_up X-Forwarded-Proto {http.request.scheme}
              }
            '';
          };
      })
      # if nginx is enabled, configure it as the reverse proxy instead
      (mkIf config.services.nginx.enable {
        services.nginx.virtualHosts."${cfg.domain}" =
          let
            inherit (config.services.immich) port;
          in
          {
            # enableACME = true;
            # forceSSL = true;
            useACMEHost = "home.elizas.website";
            locations."/" = {
              proxyPass = "http://[::1]:${toString port}";
              proxyWebsockets = true;
              recommendedProxySettings = true;
              extraConfig = ''
                client_max_body_size 50000M;
                proxy_read_timeout   600s;
                proxy_send_timeout   600s;
                send_timeout         600s;
              '';
            };
          };
      })
    ]);
}
