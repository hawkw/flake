{ config, pkgs, lib, ... }:

with pkgs; with lib; {

  imports = [ ./hardware-configuration.nix ./disko-config.nix ];

  # agenix-rekey: this host decrypts its secrets with a TPM-sealed *age*
  # identity (via age-plugin-tpm), NOT with its SSH host key. The SSH host key
  # lives in the TPM (`services.ssh-tpm-hostkeys`) and cannot be used by age to
  # decrypt --- TPMs issue ECDSA/RSA signing keys, which age either can't use as
  # a recipient (ECDSA) or can't drive for decryption (the key never leaves the
  # TPM). So secret decryption gets its own TPM-bound age identity, which keeps
  # the secrets decryptable only on this host's TPM. See README for how to
  # generate the identity + recipient and fill in the placeholders below.
  age.rekey.hostPubkey = "age1tpm1qREPLACE_ME"; # TODO: the `age1tpm1…` recipient from `age-plugin-tpm`
  age.rekey.agePlugins = [ pkgs.age-plugin-tpm ];
  # The age-plugin-tpm identity stub. It only *references* the TPM-sealed key
  # (the secret never leaves the TPM), and is created on the host during install
  # (see README). Using a runtime string path, rather than the SSH host key
  # default, both clears the `age.identityPaths must be set` assertion and
  # points decryption at the TPM identity.
  age.identityPaths = [ "/etc/age/host-identity.txt" ];

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

  # age.secrets.hakofoundry-secret = {
  #   generator.script = "base64";
  # };
  # # Generate a file in the .env format
  # age.secrets.hakofoundry-env = {
  #   generator = {
  #     dependencies = {
  #       inherit (config.age.secrets) hakofoundry-secret;
  #     };
  #     script = { pkgs, lib, decrypt, deps, ... }: ''
  #       printf 'SECRET="%s"\n' $(${decrypt} ${lib.escapeShellArg deps.hakofoundry-secret.file})
  #     '';
  #   };
  # };
  #
  # services.hakoFoundry = {
  #   enable = true;
  #   secretFilePath = config.age.secrets.hakofoundry-env.path;
  #   openFirewall = true;
  # };

  environment.systemPackages = with pkgs; [
    # age plugin for the TPM-sealed agenix identity (also used at
    # secret-decryption time during activation).
    age-plugin-tpm
    sbctl
    fwupd
    # various LSI SAS card thingies
    storcli2
    lsirec
    lsiutil
    lsscsi
    # seagate drive firmware utility
    openseachest
    sg3_utils
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

      # Lanzaboote currently replaces the systemd-boot module.
      # This setting is usually set to true in configuration.nix
      # generated at installation time. So we force it to false
      # for now.
      systemd-boot.enable = mkForce false;
      efi = {
        canTouchEfiVariables = true;
        # Primary ESP at the standard `/boot` mountpoint so `sbctl`/`bootctl`
        # can find it (they only probe `/efi`, `/boot`, `/boot/efi` by default).
        # The second disk's ESP is added via
        # `boot.lanzaboote.extraEfiSysMountPoints` below.
        efiSysMountPoint = "/boot";
      };
    };

    # Secure Boot via lanzaboote. lzbt signs the UKI and installs the
    # bootloader to *every* ESP listed, so the system boots (and verifies)
    # from either NVMe device. This requires the systemd-based initrd.
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 8;
      extraEfiSysMountPoints = [ "/boot2" ];
      # Automatically provision the Secure Boot keys on first boot.
      autoGenerateKeys.enable = true;
      autoEnrollKeys = {
        enable = true;
        # Microsoft keys are included to ensure signed option ROMs (such as the
        # LSI SAS HBAs in this box) are not locked out.
        includeMicrosoftKeys = true;
      };
    };

    initrd.supportedFilesystems = [ "zfs" ];
    # systemd-based initrd is required for clevis TPM unlocking and for
    # lanzaboote's extraEfiSysMountPoints.
    initrd.systemd = {
      enable = true;
      # Allow a root rescue shell in the initrd emergency target. Without this,
      # a failed pool import (or any stage-1 failure) drops to emergency mode
      # with root locked, which strands a headless box. This is reachable only
      # *before* the pool is unlocked, so it exposes no decrypted data. It's
      # just for debugging, and manually unlocking the pool if necessary.
      emergencyAccess = true;
    };
    # Unattended unlock of the root pool's encryption root from the TPM via
    # clevis. The JWE seals the ZFS passphrase against *this machine's* TPM
    # (empty policy, no PCR binding), so it survives kernel/firmware updates and
    # is only decryptable on this host, which makes it safe to commit. If the
    # TPM ever refuses, ZFS falls back to prompting for the passphrase, so that
    # the root FS can still be unlocked manually.
    #
    # The JWE is generated on the running system after first boot (see README);
    # it only needs root TPM access, not Secure Boot enrollment. Until it has
    # been committed, clevis is disabled and the pool is unlocked by entering
    # the passphrase at the prompt. This keeps the configuration evaluable
    # before the secret exists, which is necessary for installation.
    initrd.clevis = lib.mkIf (builtins.pathExists ./tranquility-rpool-crypt.jwe) {
      enable = true;
      devices."tranquility-rpool/crypt".secretFile = ./tranquility-rpool-crypt.jwe;
    };
    # Request ZFS encryption credentials for the root pool's encryption root at
    # boot (satisfied unattended by clevis, above).
    zfs.requestEncryptionCredentials = [ "tranquility-rpool/crypt" ];
    # Force-import the root pool at boot (`zpool import -f`). This is fine to do
    # for the root zpool, as it is not shared over the network.
    zfs.forceImportRoot = true;

    kernelModules = [ "bnxt_en" "e1000e" "alx" "r8169" "igb" "cdc_ether" "r8152" ];

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
      "bnxt_en" # Broadcom NetExtreme
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
  # # start ttyS0 early so that IPMI SoL works
  # systemd.services."serial-getty@ttyS0".wantedBy = [ "multi-user.target" ];

  # TPM 2.0-backed SSH hostkeys using ssh-tpm-agent.
  services.ssh-tpm-hostkeys.enable = true;
  services.openssh.enable = true;

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
