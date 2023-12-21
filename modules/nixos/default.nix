{ pkgs, ... }:

let eliza = "eliza";
in {
  imports = [
    ./profiles/docs.nix
    ./profiles/games.nix
    ./profiles/gnome3.nix
    ./profiles/kde.nix
    ./profiles/observability.nix
    ./profiles/perftools.nix
    ./profiles/networking.nix
    ./programs/openrgb.nix
  ];

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  console = { keyMap = "us"; };

  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";k3d

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

    # makes dynamic binaries not built for NixOS work! :D
    # see: https://github.com/Mic92/nix-ld
    nix-ld.enable = true;

    _1password.enable = true;
    _1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "eliza" ];
    };
  };

  # custom networking settings
  profiles.networking.enable = true;

  #### Services ####

  services = {
    # List services that you want to enable:

    # Enable CUPS to print documents.
    printing.enable = true;

    udev.extraRules = ''
      # Rule for the Ergodox EZ Original / Shine / Glow
      SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="1307", TAG+="uaccess"
      # Rule for the Planck EZ Standard / Glow
      SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="6060", TAG+="uaccess"
    '';
  };

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
    settings.trusted-users = [ "root" eliza ];

    # It's good to do this every now and then.
    gc = {
      automatic = true;
      dates = "monthly"; # See `man systemd.time 7`
    };
  };

  #### Hardware ####

  hardware = { bluetooth.enable = true; };

  #### users ####

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.eliza = {
    isNormalUser = true;
    extraGroups = [
      "wheel" # Enable ‘sudo’ for the user.
      "networkmanager"
      "audio"
      "docker" # Enable docker.
      "podman" # Enable podman.
      "wireshark" # of course i want to be in the wireshark group!
      "dialout" # allows writing to serial ports
    ];
    shell = pkgs.zsh;
  };

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
