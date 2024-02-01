{ pkgs, lib, ... }:

{
  imports = [
    ./profiles/desktop
    ./profiles/docs.nix
    ./profiles/games.nix
    ./profiles/laptop.nix
    ./profiles/networking.nix
    ./profiles/nix-ld.nix
    ./profiles/observability.nix
    ./profiles/perftools.nix
    ./programs/openrgb.nix
    ./programs/xfel.nix
  ];

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  console = { keyMap = "us"; };
  i18n =
    let locale = "en_US.UTF-8";
    in {
      defaultLocale = locale;
      extraLocaleSettings = {
        LC_ADDRESS = locale;
        LC_IDENTIFICATION = locale;
        LC_MEASUREMENT = locale;
        LC_MONETARY = locale;
        LC_NAME = locale;
        LC_NUMERIC = locale;
        LC_PAPER = locale;
        LC_TELEPHONE = locale;
        LC_TIME = locale;
      };
    };

  #### Programs & Packages ####

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment = {
    systemPackages = with pkgs; [
      wget
      vim
      ddate
      testdisk
      git
      nano
      pciutils
      home-manager
      lm_sensors
    ];

    # "Don't forget to add `environment.pathsToLink = [ "/share/zsh" ];` to your
    # system configuration to get completion for system packages (e.g. systemd)."
    #  --- https://nix-community.github.io/home-manager/options.html#opt-programs.zsh.enableCompletion
    pathsToLink = [ "/share/zsh" ];
  };

  programs = {
    # Some programs need SUID wrappers, can be configured further or are
    # started in user sessions.
    mtr.enable = true;
    zsh.enable = true;
  };

  profiles = {
    # custom networking settings
    networking.enable = lib.mkDefault true;

    # makes dynamic binaries not built for NixOS work! :D
    # see: https://github.com/Mic92/nix-ld
    nix-ld.enable = lib.mkDefault true;
  };

  #### Services ####

  # provides a FUSE filesystem on `/bin` that includes everything in the `PATH`,
  # allowing shell scripts that have shebangs like `/bin/bash` to work on nixos.
  # see: https://github.com/mic92/envfs
  # unfortunately, this doesn't actually seem to work for me...
  # services.envfs.enable = lib.mkDefault true;

  # Enable the Docker daemon.
  virtualisation.docker = {
    enable = true;
    # Docker appears to select `devicemapper` by default, which is not cool.
    storageDriver = "overlay2";
    # Prune the docker registry weekly.
    autoPrune.enable = true;
    extraOptions = ''
      --experimental
    '';
    # workaround for https://github.com/moby/moby/issues/45935, see
    # https://github.com/armbian/build/issues/5586#issuecomment-1677708996
    # or i could try podman...
    package = pkgs.docker_24;
  };

  #### nix configurations ####

  nixpkgs.config.allowUnfree = true;

  nix = {
    # enable flakes
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    generateNixPathFromInputs = true;
    generateRegistryFromInputs = true;
    linkInputs = true;
    settings.trusted-users = [ "root" "eliza" ];

    # It's good to do this every now and then.
    gc = {
      automatic = true;
      dates = "monthly"; # See `man systemd.time 7`
    };
  };

  #### users ####

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.eliza = {
    isNormalUser = true;
    extraGroups = [
      "wheel" # Enable ‘sudo’ for the user.
      "audio"
      "docker" # Enable docker.
      "podman" # Enable podman.
      "wireshark" # of course i want to be in the wireshark group!
      "dialout" # allows writing to serial ports
    ];
    shell = pkgs.zsh;
  };

  security.sudo.configFile = ''
    Defaults    env_reset,pwfeedback
  '';
}
