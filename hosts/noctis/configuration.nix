{ config, pkgs, lib, ... }:

{

  imports = [ ./hardware-configuration.nix ./filesystems.nix ];

  system.stateVersion = "22.11";

  profiles = let rootDomain = "elizas.website"; in {
    docs.enable = true;
    games.enable = true;
    desktop = {
      gnome3.enable = true;
    };
    observability = {
      # enable = true;
      # observer = {
      #   enable = true;
      #   enableUnifi = true;
      #   inherit rootDomain;
      # };
      snmp.enable = true;
    };
    # nginx = {
    #   enable = true;
    #   domain = rootDomain;
    #   acmeSubdomain = "home";
    # };
    # enable the correct perf tools for this kernel version
    perftools.enable = true;
    vu-dials.enable = true;
    zfs.enable = true;

    arm-cross-dev.enable = true;
    nix-ld.enable = true;
  };

  hardware = {
    probes = {
      cmsis-dap.enable = true;
      espressif.enable = true;
      st-link.enable = true;
    };
  };

  #### Boot configuration ####
  boot = {
    loader = {
      # Use the systemd-boot EFI boot loader.
      systemd-boot = {
        enable = true;
        # don't keep more than 32 old configurations, to keep the /boot
        # partition from filling up.
        configurationLimit = 32;
      };
      efi.canTouchEfiVariables = true;
    };

    # Use this to track the latest Linux kernel that has ZFS support.
    # This is generally not as necessary while using `zfsUnstable = true`.
    # kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

    # The Zen kernel is tuned for better performance on desktop/workstation
    # machines, rather than power efficiency on laptops/small devices. Use that!
    # kernelPackages = pkgs.linuxPackages_zen;

    ### configuration for unlocking the encrypted ZFS root dataset over SSH ###
    # based on
    # https://gitlab.com/usmcamp0811/dotfiles/-/blob/nixos/modules/nixos/system/zfs/default.nix
    #
    # TO REMOTELY UNLOCK ZPOOL:
    #
    # ssh root@10.0.10.42 -p 22
    # zfs load-key -a
    # <enter password>
    #
    # kernel modules for network adapters
    kernelModules = [ "e1000e" "alx" "r8169" "igb" "cdc_ether" "r8152" ];
    # TODO(eliza): this could be a static IP so that we don't depend on DHCP
    # working to boot...
    kernelParams = [ "ip=dhcp" ];

    # additional kernel modules
    initrd.availableKernelModules = [
      "usb_storage"
      "sd_mod"
      # enable initrd kernel modules for network adapters.
      #
      # these can be found using `sudo lspci -v -nn -d '::0200'` to find Ethernet
      # controllers and `sudo lscpi -v -nn -d '::0280'` to find wireless
      # controllers, and then looking for the "Kernel driver in use" line.
      "igb" # Intel GigaBit Ethernet
      "iwlwifi" # Intel WiFi
      # other network adapters. these aren't currently present on my system, but
      # let's enable them anyway in case it grows additional hardware
      # later.abort
      "thunderbolt"
      "usbnet"
      "r8152"
      "igc"
      "cdc_ether"
    ];
    initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        port = 22;
        authorizedKeys = config.users.users.eliza.openssh.authorizedKeys.keys;
        # WARNING: these must actually exist :)
        hostKeys = [
          "/etc/ssh/ssh_host_rsa_key"
          "/etc/ssh/ssh_host_ed25519_key"
        ];
      };
    };
  };

  #### System configuration ####
  networking = {
    # machine's hostname
    hostName = "noctis";
    # this has to be a unique 32-bit number. ZFS requires us to define this.
    hostId = "FADEFACE";

    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = false;
    interfaces =
      let
        wakeOnLan = {
          enable = true;
          policy = [ "unicast" "magic" ];
        };
        # disable dhcpd and use networkmanager instead.
        useDHCP = true;
      in
      {
        enp5s0 = { inherit wakeOnLan useDHCP; };
        enp7s0 = { inherit wakeOnLan useDHCP; };
        enp8s0f1u1u1u2 = { inherit wakeOnLan useDHCP; };
        wlp4s0 = { inherit useDHCP; };
        wlp7s0 = { inherit useDHCP; };
      };
  };

  # This is a deskop machine. Use the high-performance frequency profile rather
  # than the low-power one.
  powerManagement.cpuFreqGovernor = "performance";

  # high-DPI console font
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-u28n.psf.gz";

  # i have 24 cores
  nix.settings.max-jobs = 24;

  #### Programs ####
  programs = {
    # Used specifically for its (quite magical) "copy as html" function.
    gnome-terminal.enable = true;
    openrgb.enable = true;

    xfel.enable = true;
  };

  #### Services ####
  services = {
    openrgb.enable = true;
    # FOR CVE REASONS
    printing.enable = lib.mkForce false;
  };

  # services.tailscale =
  #   let
  #     labMgmtNet = "10.0.50.0/24";
  #     labServerNet = "10.0.60.0/24";
  #   in
  #   {
  #     useRoutingFeatures = "server";
  #     extraUpFlags = [
  #       "--advertise-routes=${labMgmtNet},${labServerNet}"
  #     ];
  #   };

  # disable the Gnome keyring, since we are using 1password to manage secrets
  # instead.
  services.gnome.gnome-keyring.enable = lib.mkForce false;
  security.pam.services.login.enableGnomeKeyring = lib.mkForce false;

  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │
    └┴────────────────┘
    ${config.networking.hostName}: workstation
  '';
}
