{ config, lib, pkgs, ... }:

with lib;
let cfg = config.profiles.networking;
in {
  options.profiles.networking = with lib; {
    enable = mkEnableOption "Network profile";
  };

  config = lib.mkIf cfg.enable {
    #### Networking Configuration ####

    networking = {
      # use networkmanager.
      networkmanager.enable = true;
      # disable wpa_supplicant, as NetworkManager is used instead.
      wireless.enable = false;
      # `dhcpcd` conflicts with NetworkManager's `dhclient`, as they try to bind
      # the same address; it needs to be explicitly disabled.
      dhcpcd.enable = false;

      # Configure network proxy if necessary
      # networking.proxy.default = "http://user:password@proxy:port/";
      # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

      # Open ports in the firewall.
      # .allowedTCPPorts = [ ... ];
      # networking.firewall.allowedUDPPorts = [ ... ];
      # Or disable the firewall altogether.
      # networking.firewall.enable = false;

      # Strict reverse path filtering breaks Tailscale exit node use and some
      # subnet routing setups.
      firewall.checkReversePath = "loose";
      firewall.trustedInterfaces = [
        "docker0" # docker iface is basically loopback
        "tailscale0Link" # tailscale
      ];

      # enable mdns resolution for resolved on all connections
      # see https://man.archlinux.org/man/NetworkManager.conf.5#CONNECTION_SECTION
      networkmanager.connectionConfig."connection.mdns" = 2;
    };

    services = {
      # Enable the OpenSSH daemon.
      openssh = {
        enable = true;
        settings = { X11Forwarding = true; };
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
          # publish ._workstation._tcp
          workstation = true;
          domain = true;
          # publish user services running on this machine
          userServices = true;
          # publish a HINFO record, which contains information about the local
          # operating system and CPU.
          hinfo = true;
        };
      };

      # enable tailscale
      tailscale.enable = true;

      resolved.enable = true;
    };

    environment.systemPackages = with pkgs; [
      networkmanager
      networkmanagerapplet
      openssh
      bluedevil
      bluez
      tailscale
      ethtool
    ];

    users.users.eliza.extraGroups = [ "networkmanager" ];
  };
}
