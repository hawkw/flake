{ config, lib, pkgs, ... }:

with lib;
let cfg = config.profiles.networking;
in with lib; {
  options.profiles.networking = {
    enable = mkEnableOption "Network profile";
  };

  config = mkIf cfg.enable {
    #### Networking Configuration ####

    networking = {
      # use networkmanager.
      networkmanager = {
        enable = lib.mkDefault true;
        plugins = with pkgs; [ networkmanager-openvpn ];
      };
      # disable wpa_supplicant, as NetworkManager is used instead.
      # wireless.enable = false;
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

    programs.mosh.enable = mkDefault true;

    services = {
      # Enable the OpenSSH daemon.
      openssh = {
        enable = true;
        settings = {
          X11Forwarding = true;
          # Necessary to use forwarded SSH keys for Git signing etc.
          AllowAgentForwarding = true;
          # Drop connections whose client has gone away (e.g. a laptop that
          # suspended) after ~90s, rather than when TCP keepalive gives up
          # (2h+). This is mainly intended for hosts which suspend on idle,
          # since logind considers non-pty SSH sessions as "activity" as long as
          # it's up.
          ClientAliveInterval = 30;
          ClientAliveCountMax = 3;
        };
      };

      # DNS configurations --- Avahi (mDNS)
      avahi = {
        # allow local applications to resolve `local.` domains using avahi.
        enable = true;
        # publish this machine on mDNS.
        settings = {
          server.use-ipv4 = true;
          publish = {
            publish-addresses = true;
            disable-user-service-publishing = false;
            # publish ._workstation._tcp
            publish-workstation = true;
            publish-domain = true;
            # publish a HINFO record, which contains information about the local
            # operating system and CPU.
            publish-hinfo = true;
          };
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
      kdePackages.bluedevil
      bluez
      tailscale
      ethtool
      dig
    ];

    users.users.eliza.extraGroups = [ "networkmanager" ];
  };
}
