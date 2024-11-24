{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.docker-dashy;
  configFile = pkgs.runCommand "conf.yml"
    {
      buildInputs = [ pkgs.yj ];
      preferLocalBuild = true;
    } ''
    yj -jy < ${pkgs.writeText "config.json" (builtins.toJSON cfg.settings)} > $out
  '';
in
{
  options.services.docker-dashy = {
    enable = mkEnableOption "dashy";
    imageTag = mkOption {
      type = types.str;
      default = "2.1.1";
    };
    port = mkOption {
      type = types.int;
      default = 8081;
    };
    settings = mkOption {
      type = types.attrs;
    };
    # extraOptions = mkOption { };
  };

  # docker-dashy.service
  config = mkIf cfg.enable {

    # Dashy docker service
    virtualisation.oci-containers.containers = {
      dashy = {
        image = "lissy93/dashy:${cfg.imageTag}";
        extraOptions = [ "-p" "${toString cfg.port}:80" ];
        environment = {
          TZ = "${config.time.timeZone}";
        };
        volumes = [
          "${configFile}:/app/public/conf.yml"
        ];
      };
    };
  };

}
