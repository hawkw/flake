{ config, lib, pkgs, ... }:

with lib; {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJLA1+OlP+jULnVvoP0wBZJIKeXadYQB4V90YAJnm3T";

  networking.hostName = "theseus"; # Define your hostname.

  profiles = {
    docs.enable = true;
    laptop.enable = true;
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
    # vu-dials.enable = true;
    observability.enable = true;
    arm-cross-dev.enable = true;
    nix-ld.enable = true;
    games.enable = true;
    yubikey = {
      enable = true;
      provisioning.enable = true;
      pam_u2f = {
        enable = true;
        lockOnUnplug = true;
      };
    };
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

  #### System configuration ####

  # Bootloader.
  boot = {
    loader.efi.canTouchEfiVariables = true;

    # use the latest stable Linux kernel
    kernelPackages = pkgs.linuxPackages_latest;

    ### FDE unlock via YubiKey (systemd-cryptenroll FIDO2) ###
    #
    # Both LUKS volumes (root, declared in hardware-configuration.nix, and
    # swap, declared here) carry FIDO2 enrollments made with
    # `systemd-cryptenroll --fido2-device=auto <blockdev>`, one per YubiKey
    # (see modules/nixos/profiles/yubikey.nix for the overall scheme). Swap is
    # enrolled too, and with the same PIN-required policy: it must unlock in
    # the initrd on the hibernate-resume path, and a hibernation image
    # contains the root volume master key, so a weaker policy on swap would
    # undermine the one on root.
    #
    # The original memorized passphrase remains enrolled (keyslot 0) on both
    # volumes as the disaster-recovery path; systemd-cryptsetup falls back to
    # a passphrase prompt when no token responds within token-timeout.
    #
    # FIDO2 unlock requires the systemd-based stage 1; the scripted-initrd
    # fido2 path (fido2luks) is deprecated and incompatible with it.
    initrd.systemd = {
      enable = true;
      # Allow a root rescue shell in the initrd emergency target. Without
      # this, any stage-1 failure drops to emergency mode with root locked,
      # and un-stranding the machine requires a live USB. This is reachable
      # only *before* the volumes are unlocked, so it exposes no decrypted
      # data.
      emergencyAccess = true;
    };

    initrd.luks.devices =
      let
        # Luks options to enable 
        crypttabExtraOpts = [
          "fido2-device=auto"
          # How long to wait for a FIDO2 token before falling back to the
          # passphrase prompt (i.e. when booting with no yubikey plugged in).
          "token-timeout=10s"
        ];
      in
      {
        # root
        "luks-d315acae-6096-482b-8dbd-ff53e0df180c".crypttabExtraOpts = crypttabExtraOpts;
        # swap
        "luks-c8e922ff-11e1-473c-a52e-c2b86a042e44" = {
          device = "/dev/disk/by-uuid/c8e922ff-11e1-473c-a52e-c2b86a042e44";
          inherit crypttabExtraOpts;
        };
      };

    ### secureboot using Lanzaboote ###
    # TODO: move this to a module?
    lanzaboote = {
      enable = true;
      pkiBundle = "/etc/secureboot";
      # don't keep more than 8 old configurations, to keep the /boot partition
      # from filling up.
      configurationLimit = 8;
    };

    # Lanzaboote currently replaces the systemd-boot module.
    # This setting is usually set to true in configuration.nix
    # generated at installation time. So we force it to false
    # for now.
    loader.systemd-boot.enable = mkForce false;
  };

  environment.systemPackages = with pkgs; [
    # For debugging and troubleshooting Secure Boot.
    sbctl
  ];

  programs = {
    # Used specifically for its (quite magical) "copy as html" function.
    gnome-terminal.enable = true;

    xfel.enable = true;
  };

  # COSMIC
  services = {
    desktopManager.cosmic.enable = true;
    # displayManager = {
    #   # cosmic-greeter.enable = true;
    #   defaultSession = "cosmic";
    #   gdm.enable = false;
    # };
  };

  networking.hosts = {
    "172.20.36.4" = [ "recovery.sys.dublin.eng.oxide.computer" ];
  };

  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │
    └┴────────────────┘
    ${config.networking.hostName}: mobile workstation
  '';

  # As of firmware v03.03, a bug in the EC causes the system to wake if AC is
  # connected despite the lid being closed. The following works around this,
  # with the trade-off that keyboard presses also no longer wake the system.
  # see https://github.com/NixOS/nixos-hardware/tree/7763c6fd1f299cb9361ff2abf755ed9619ef01d6/framework/13-inch/7040-amd#suspendwake-workaround
  # hardware.framework.amd-7040.preventWakeOnAC = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
