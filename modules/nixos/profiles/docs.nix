{ config, lib, pkgs, ... }:
let cfg = config.profiles.docs;
in {
  options.profiles.docs = with lib; {
    enable = mkEnableOption "documentation profile";
  };

  config = lib.mkIf cfg.enable {
    ### documentation ###
    documentation = {
      # install documentation from all packages `environment.systemPackages`.
      enable = true;
      # enable documentation distributed in packages' `/share/doc`.
      doc.enable = true;

      man = {
        # enable manpages
        enable = true;
        # generate manpage index caches to enable searching using `man -k`.
        generateCaches = true;
      };
      # info.enable = true;

      # enable packages' developer documentation
      dev.enable = true;

      # install nixos' own documentation
      nixos.enable = true;
    };

    environment.systemPackages = with pkgs; [
      # i want all the man pages
      man-pages
      man-pages-posix
      # manpage-style rustdoc viewer
      rusty-man
      # a fast documentation viewer for nix
      manix
      # Parse formatted man pages and man page source from most flavors of UNIX and converts them to HTML, ASCII, TkMan, DocBook, and other formats
      rman
    ];
  };
}
