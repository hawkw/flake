{ config, lib, ... }:

let
  cfg = config.profiles.eclss-node;
in
with lib;
{
  options = {
    profiles.eclss-node.enable = mkEnableOption "Raspberry Pi 3 ECLSS node profile";
  };

  config = mkIf cfg.enable {
    profiles = {
      networking.enable = true;
      raspberry-pi = {
        i2c.enable = true;
        spi.enable = true;
        gpio.enable = true;
        pi3.enable = true;
      };
      observability.enable = true;
    };

    services.prometheus.exporters = {
      # no drives with SMART support here...
      smartctl.enable = false;
    };

    # don't need docker
    virtualisation.docker.enable = mkForce false;

    networking = {
      wireless = {
        enable = mkForce true;
        environmentFile = "/var/secrets/wireless.env";
        networks."ManyPaws".psk = "@PSK_MANYPAWS@";
      };

      networkmanager.enable = mkForce false;
      useNetworkd = mkForce true;

      interfaces."wlan0".useDHCP = true;
      interfaces."eth0".useDHCP = false;
      firewall = {
        allowedTCPPorts = [ config.services.eclssd.server.port 22 ];
        # Strict reverse path filtering breaks Tailscale exit node use and some
        # subnet routing setups.
        checkReversePath = "loose";
        trustedInterfaces = [
          "tailscale0Link" # tailscale
        ];
      };
    };

    # OpenSSH is forced to have an empty `wantedBy` on the installer system[1], this won't allow it
    # to be automatically started. Override it with the normal value.
    # [1] https://github.com/NixOS/nixpkgs/blob/9e5aa25/nixos/modules/profiles/installation-device.nix#L76
    systemd.services.sshd.wantedBy = mkForce [ "multi-user.target" ];

    services = {
      eclssd = {
        enable = true;
        logging = {
          timestamps = false;
          format = "journald";
          filter = "info";
        };
      };
      tailscale.enable = true;

      # Enable the OpenSSH daemon.
      openssh = {
        enable = true;
        openFirewall = true;
        settings.PermitRootLogin = "yes";
        listenAddresses = [{ addr = "0.0.0.0"; port = 22; }];
      };

      # DNS configurations --- Avahi (mDNS)
      avahi = {
        enable = true;
        # allow local applications to resolve `local.` domains using avahi.
        # nssmdns4 = true;
        ipv4 = true;
        # ipv6 = true;
        # publish this machine on mDNS.
        publish = {
          enable = true;
          addresses = true;
          domain = true;
          # publish user services running on this machine
          userServices = true;
          # publish a HINFO record, which contains information about the local
          # operating system and CPU.
          hinfo = true;
        };
      };
    };

    users.motd = ''
      ┌┬────────────────┐
      ││ ELIZA NETWORKS │ ${config.networking.hostName}: environmental monitoring and control
      └┴────────────────┘
    '';
  };
}
