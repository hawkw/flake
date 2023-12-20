{ config, pkgs, ... }:

{

  imports = [ ./hardware-configuration.nix ./filesystems.nix ];

  system.stateVersion = "22.11";

  profiles = {
    docs.enable = true;
    games.enable = true;
    gnome3.enable = true;
    observability.enable = true;
    # enable the correct perf tools for this kernel version
    perftools.enable = true;
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

    # makes dynamic binaries not built for NixOS work! :D
    # see: https://github.com/Mic92/nix-ld
    nix-ld.enable = true;

    _1password.enable = true;
    _1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "eliza" ];
    };
  };

  #### Services ####
  services = {
    openrgb.enable = true;
    # logid.enable = true;

    # DNS configurations --- Avahi (mDNS)
    avahi = {
      enable = true;
      # allow local applications to resolve `local.` domains using avahi.
      nssmdns = true;
      ipv4 = true;
      ipv6 = true;
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

  };

  ### xfel ###
  # add xfel udev rules
  services.udev.packages = [ pkgs.xfel ];
  environment.systemPackages = [ pkgs.xfel ];

  ### pipewire ###
  # don't use the default `sound` config (alsa)
  sound.enable = false;
  # Use PipeWire as the system audio/video bus
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };
    jack.enable = true;
    pulse.enable = true;
    socketActivation = true;
  };

  security.sudo.configFile = ''
    Defaults    env_reset,pwfeedback
  '';

}
