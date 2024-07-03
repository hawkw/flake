{ config, pkgs, lib, ... }:

with lib; {

  options.profiles.nix-ld = {
    enable = mkEnableOption "nix-ld profile";
  };

  #### nix configurations ####
  config = mkMerge [
    {
      nixpkgs.config.allowUnfree = true;

      nix = {
        package = pkgs.lix;
        extraOptions = ''
          experimental-features = nix-command flakes
        '';
        generateNixPathFromInputs = true;
        generateRegistryFromInputs = true;
        linkInputs = true;

        # It's good to do this every now and then.
        gc = {
          automatic = true;
          dates = "monthly"; # See `man systemd.time 7`
        };

        settings =
          let
            substituters = [
              "https://nix-community.cachix.org"
              "https://cache.garnix.io"
            ];
          in
          {
            trusted-users = [ "root" "eliza" ];
            extra-substituters = substituters;
            trusted-substituters = substituters;
            extra-trusted-public-keys = [
              "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
              "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
            ];
          };
      };
    }

    (mkIf config.profiles.nix-ld.enable {

      # Enable nix ld
      programs.nix-ld = {
        enable = true;
        libraries = with pkgs; [
          alsa-lib
          at-spi2-atk
          at-spi2-core
          atk
          cairo
          cups
          curl
          dbus
          expat
          fontconfig
          freetype
          fuse3
          gdk-pixbuf
          glib
          gtk3
          icu
          libGL
          libappindicator-gtk3
          libdrm
          libglvnd
          libnotify
          libpulseaudio
          libunwind
          libusb1
          libuuid
          libxkbcommon
          libxml2
          mesa
          nspr
          nss
          openssl
          pango
          pipewire
          stdenv.cc.cc
          systemd
          vulkan-loader
          xorg.libX11
          xorg.libXScrnSaver
          xorg.libXcomposite
          xorg.libXcursor
          xorg.libXdamage
          xorg.libXext
          xorg.libXfixes
          xorg.libXi
          xorg.libXrandr
          xorg.libXrender
          xorg.libXtst
          xorg.libxcb
          xorg.libxkbfile
          xorg.libxshmfence
          zlib
        ];
      };
    })
  ];


}
