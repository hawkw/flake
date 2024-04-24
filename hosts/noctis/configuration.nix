{ config, pkgs, ... }:

{

  imports = [ ./hardware-configuration.nix ./filesystems.nix ];

  system.stateVersion = "22.11";

  profiles = {
    docs.enable = true;
    games.enable = true;
    desktop = {
      gnome3.enable = true;
    };
    observability.enable = true;
    # enable the correct perf tools for this kernel version
    perftools.enable = true;
  };

  hardware = {
    probes = {
      cmsis-dap.enable = true;
      espressif.enable = true;
      st-link.enable = true;
    };
    tpm.enable = true;
    framework-amd.enable = true;
  };

  #### Boot configuration ####
  boot = {
    loader = {
      # Use the systemd-boot EFI boot loader.
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # Use this to track the latest Linux kernel that has ZFS support.
    # This is generally not as necessary while using `zfsUnstable = true`.
    kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

    # The Zen kernel is tuned for better performance on desktop/workstation
    # machines, rather than power efficiency on laptops/small devices. Use that!
    # kernelPackages = pkgs.linuxPackages_zen;

    # additional kernel modules
    initrd.availableKernelModules = [ "usb_storage" "sd_mod" ];
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
    interfaces = {
      enp5s0.useDHCP = true;
      wlp4s0.useDHCP = true;
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
    # logid.enable = true;
    # VU1 Dials server
    vu-dials = {
      server = {
        enable = true;
        logLevel = "info";
      };
      vupdated = {
        enable = true;
        enableHotplug = true;
        logFilter = "info,vupdated=debug";
        dials =
          let
            backlight =
              {
                mode = {
                  static = {
                    red = 100;
                    green = 65;
                    blue = 0;
                  };
                };
              };
            update-interval = "1s";
          in
          {
            "CPU Load" = {
              index = 0;
              metric = "cpu-load";
              inherit update-interval backlight;
            };
            "CPU Temp" = {
              index = 1;
              metric = "cpu-temp";
              inherit update-interval backlight;
            };
            "Memory Usage" = {
              index = 2;
              metric = "mem";
              inherit update-interval backlight;
            };
            "Swap Usage" = {
              index = 3;
              metric = "swap";
              inherit update-interval backlight;
            };
          };
      };
    };
  };

  # disable the Gnome keyring, since we are using 1password to manage secrets
  # instead.
  services.gnome.gnome-keyring.enable = lib.mkForce false;
  security.pam.services.login.enableGnomeKeyring = lib.mkForce false;

}
