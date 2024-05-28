{ config, lib, ... }:
with lib; {
  system.stateVersion = "23.11";
  raspberry-pi.hardware.platform.type = "rpi3";


  security.sudo-rs.enable = mkForce false;

  profiles = {
    observability.enable = true;
    # don't enable the network settings used
    networking.enable = mkForce false;
  };


  networking = {
    wireless.enable = true;
    interfaces."wlan0".useDHCP = true;
    interfaces."eth0".useDHCP = true;
    firewall = {
      allowedTCPPorts = [ config.services.eclssd.server.port ];
      # Strict reverse path filtering breaks Tailscale exit node use and some
      # subnet routing setups.
      checkReversePath = "loose";
      trustedInterfaces = [
        "docker0" # docker iface is basically loopback
        "tailscale0Link" # tailscale
      ];
    };
  };

  # OpenSSH is forced to have an empty `wantedBy` on the installer system[1], this won't allow it
  # to be automatically started. Override it with the normal value.
  # [1] https://github.com/NixOS/nixpkgs/blob/9e5aa25/nixos/modules/profiles/installation-device.nix#L76
  systemd.services.sshd.wantedBy = mkOverride 40 [ "multi-user.target" ];

  services = {
    eclssd.enable = true;
    tailscale.enable = true;

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      openFirewall = true;
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
  users.users.eliza.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICNWunZTkQnvkKi6gbeRfOXaIg4NL0OiE0SIXosxRP6s"
  ];
}
