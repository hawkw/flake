{ config, lib, ... }: with lib; let
  cfg = config.services.hakoFoundry;
  containerPort = 8080;
in
{
  options.services.hakoFoundry = with types; {
    enable = mkEnableOption "HakoFoundry";
    openAccess = mkEnableOption "Open access (no password auth)";
    secretFilePath = mkOption {
      type = path;
      description = ''
        Path to the secret environment file.
        This must be of the form `SECRET=<base64-encoded-secret>`.
      '';
    };
    port = mkOption {
      type = uniq port;
      default = containerPort;
      example = containerPort;
      description = "The host port to bind for the HTTP server.";
    };
    configPath = mkOption {
      type = path;
      default = "/etc/hakofoundry";
      example = "/etc/hakofoundry";
      description = "Path for persistent config storage.";
    };
    openFirewall = mkOption {
      type = bool;
      default = false;
      description = ''
        Whether to open the firewall for HakoFoundry.
        This adds `services.hakoFoundry.port` to `networking.firewall.allowedTCPPorts`.
      '';
    };
  };

  config = mkIf cfg.enable {
    virtualisation.oci-containers.containers.hakoFoundry = {
      serviceName = "hako-foundry";
      image = "hakoforge/hako-foundry";
      pull = "always";
      ports = [ "${toString cfg.port}:${toString containerPort}" ];

      # see
      # https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/devices.html
      # and
      # https://www.kernel.org/doc/Documentation/admin-guide/devices.txt
      # for device major numbers
      extraOptions = [
        # character devices with major number 166 are ACM USB modems (/dev/ttyACM*)
        # we need these to talk to the HakoForge powerboard
        "--device-cgroup-rule='c 166:* rwm'"
        # block devices with major number 8 are SCSI disk devices (HDDs)
        "--device-cgroup-rule='b 8:* rwm"
      ];
      volumes = [
        "${cfg.configPath}:/app/config"
        "/dev:/dev"
        "/sys/class/thermal:/sys/class/thermal:ro"
        "/sys/class/hwmon:/sys/class/hwmon:ro"
      ];
      capabilities = {
        SYS_RAWIO = true;
      };
      environment = {
        OPEN_ACCESS = toString cfg.openAccess;
      };
      environmentFiles = [
        cfg.secretFilePath
      ];
    };

    networking.firewall = mkIf cfg.openFirewall { allowedTCPPorts = [ cfg.port ]; };
  };
}
