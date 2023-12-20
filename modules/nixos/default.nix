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
    ./programs/openrgb.nix
  ];

  #### Networking Configuration ####

  networking = {
    # use networkmanager.
    networkmanager.enable = true;
    # disable wpa_supplicant, as NetworkManager is used instead.
    wireless.enable = false;
    # `dhcpcd` conflicts with NetworkManager's `dhclient`, as they try to bind
    # the same address; it needs to be explicitly disabled.
    dhcpcd.enable = false;

    # The global useDHCP flag is deprecated, therefore explicitly set to false here.
    # Per-interface useDHCP will be mandatory in the future, so this generated config
    # replicates the default behaviour.
    useDHCP = false;
    interfaces = {
      enp5s0.useDHCP = true;
      wlp4s0.useDHCP = true;
    };

    # Configure network proxy if necessary
    # networking.proxy.default = "http://user:password@proxy:port/";
    # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

    # Open ports in the firewall.
    # networking.firewall.allowedTCPPorts = [ ... ];
    # networking.firewall.allowedUDPPorts = [ ... ];
    # Or disable the firewall altogether.
    # networking.firewall.enable = false;

    # Strict reverse path filtering breaks Tailscale exit node use and some
    # subnet routing setups.
    firewall.checkReversePath = "loose";
  };

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
      networkmanager
      networkmanagerapplet
      openssh
      bluedevil
      bluez
      tailscale
      ethtool
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
  };

  #### Services ####

  services = {
    # List services that you want to enable:

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      settings = { X11Forwarding = true; };
    };

    # Enable CUPS to print documents.
    printing.enable = true;

    udev.extraRules = ''
      # Rule for the Ergodox EZ Original / Shine / Glow
      SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="1307", TAG+="uaccess"
      # Rule for the Planck EZ Standard / Glow
      SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="6060", TAG+="uaccess"
    '';

    # enable tailscale
    tailscale.enable = true;

    # cpupower-gui.enable = true;
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
}
