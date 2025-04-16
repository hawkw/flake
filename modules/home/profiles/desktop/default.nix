# Profile for desktop machines (i.e. not servers).
{ config, lib, pkgs, ... }:
let cfg = config.profiles.desktop;
in {
  imports = [ ./gnome3.nix ./kde.nix ];

  options.profiles.desktop = with lib; {
    enable = mkEnableOption "Profile for desktop machines (i.e. not servers)";
  };

  config = lib.mkIf cfg.enable {

    home.packages = with pkgs;
      let
        unfreePkgs = [
          slack
          discord
          signal-desktop-bin
          zoom-us
          keybase
          keybase-gui
          spotify
          tdesktop
          obsidian
        ];
      in
      ([

        ### images, media, etc ###
        kdePackages.ark
        darktable
        inkscape
        obs-studio
        # broken due to https://github.com/NixOS/nixpkgs/issues/188525
        # llpp # fast & lightweight PDF pager
        krita # like the GNU Image Manipulation Photoshop, but more good
        gimp
        syncplay
        vlc
        plex-media-player
        ghostscriptX
        losslesscut-bin

        ### stuff ###
        pywal
        chromium
        torrential

        ### chat clients & stuff
        element-desktop
        mumble
      ] ++ unfreePkgs);
    #############################################################################
    ## Programs                                                                 #
    #############################################################################
    programs = {
      firefox.enable = true;
      ghostty.enable = true;
      _1password-gui.enableSshAgent = true;
      keychain = {
        enable = true;
        enableXsessionIntegration = true;
        keys = [ "id_ed25519" ];
      };
    };

    #############################################################################
    ## Services                                                                 #
    #############################################################################
    services = {
      gpg-agent.enable = true;
    };

  };
}
