{ lib, pkgs, ... }:

let
  # this has its own systemd dataset with autosnapshot disabled. see
  # disko-config.nix.
  cacheHome = "/home/eliza/.cache";
in
{
  profiles = {
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
    devtools = {
      enable = true;
      enablePython = true;
    };
    oxide = {
      enable = true;
    };
    opstools = {
      enable = true;
      net.enable = true;
      supermicro.enable = true;
    };
  };

  profiles.devtools.sccache = {
    enable = true;
    cacheDir = "${cacheHome}/sccache";
    cacheSize = "128G";
  };

  home.sessionVariables = {
    EDITOR = lib.mkForce "nano"; # headless...

    # cargo build cache config see:
    # https://doc.rust-lang.org/cargo/reference/config.html#buildbuild-dir
    #
    # N.B.: we are configuring this here rather than the `.cargo/config.toml`
    # file, because there have historically been a lot of nightmarish behaviours
    # with cargo's config merging behavior...
    CARGO_BUILD_BUILD_DIR = "${cacheHome}/cargo/build/{workspace-path-hash}";
  };

  home.packages = with pkgs; [
    # not trying to build ESP32-C3 on this machine, so global clang is fine...
    clang
    # global pkgconfig too
    pkg-config
    qemu
    screen
    claude-code
  ];

  programs.atuin =
    { enable = true; enableDaemon = true; };


  services = {
    gpg-agent = {
      enable = true;
      # pinentryFlavor = "gnome3";
    };
  };
}
