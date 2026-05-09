{ config, pkgs, lib, ... }:

with pkgs; with lib; {

  imports = [ ./hardware-configuration.nix ./disko-config.nix ];

  profiles = {
    server.enable = true;
    desktop = {
      gnome3.enable = true;
    };
    observability = {
      enable = true;
      snmp.enable = true;
    };

    zfs.enable = true;
  };


  age.secrets.hakofoundry-secret = {
    generator.script = "base64";
  };
  # Generate a file in the .env format
  age.secrets.hakofoundry-env = {
    generator = {
      dependencies = {
        inherit (config.age.secrets) hakofoundry-secret;
      };
      script = { pkgs, lib, decrypt, deps, ... }: ''
        printf 'SECRET="%s"\n' $(${decrypt} ${lib.escapeShellArg deps.hakofoundry-secret.file})
      '';
    };
  };

  services.hakoFoundry = {
    enable = true;
    secretFilePath = config.age.secrets.hakofoundry-env.file;
  };

  environment.systemPackages = with pkgs; [
    fwupd
    # various LSI SAS card thingies
    storcli2
    lsirec
    lsiutil
    lsscsi
    # seagate drive firmware utility
    openseachest
  ];

  # fwupd: firmware update
  services.fwupd.enable = true;

  #### System configuration ####
  networking = {
    # machine's hostname
    hostName = "tranquility";
    # this has to be a unique 32-bit number. ZFS requires us to define this.
    hostId = "00C0FFEE";

    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = false;
  };

  #### Boot configuration ####
  boot = {
    loader = {
      # Use the systemd-boot EFI boot loader.
      systemd-boot = {
        enable = true;
        configurationLimit = 8;
      };
      efi.canTouchEfiVariables = true;
    };

    initrd.supportedFilesystems = [ "zfs" ];
    zfs.requestEncryptionCredentials = false;

    kernelModules = [ "e1000e" "alx" "r8169" "igb" "cdc_ether" "r8152" ];
    kernelParams = [
      # console on ttyS0 to try and make IPMI SOL work...
      "console=tty0"
      "console=ttyS0,115200n8"

      # TODO(eliza): this could be a static IP so that we don't depend on DHCP
      # working to boot...
      "ip=dhcp"
    ];

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
      # ssh = {
      #   enable = true;
      #   port = 22;
      #   authorizedKeys = config.users.users.eliza.openssh.authorizedKeys.keys;
      #   # # WARNING: these must actually exist :)
      #   # hostKeys = [
      #   #   "/etc/ssh/ssh_host_rsa_key"
      #   #   "/etc/ssh/ssh_host_ed25519_key"
      #   # ];
      # };
    };
  };
  # enable ssh early
  systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
  # start ttyS0 early so that IPMI SoL works
  systemd.services."serial-getty@ttyS0".wantedBy = [ "multi-user.target" ];


  users.motd = ''
    ┌┬────────────────┐
    ││ ELIZA NETWORKS │
    └┴────────────────┘
    ${config.networking.hostName}: storage
  '';


  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?


}
