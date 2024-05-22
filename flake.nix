{
  description = "Eliza's NixOS and Home-Manager configuration flake";

  ############################################################################
  #### INPUTS ################################################################
  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs?ref=nixos-23.11";
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    home = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware/master";

    utils = {
      url = "github:gytis-ivaskevicius/flake-utils-plus/v1.4.0";
      inputs.flake-utils.follows = "flake-utils";
    };

    vu-server = {
      url = "github:hawkw/vu-server-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    vupdaters = {
      url = "https://flakehub.com/f/mycoliza/vupdaters/0.1.116.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        vu-server.follows = "vu-server";
      };
    };

    # for secureboot support on theseus
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.3.0";

      # Optional but recommended to limit the size of your system closure.
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    # for building Rust packages
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    # fw ectool as configured for FW13 7040 AMD (until patch is upstreamed)
    fw-ectool = {
      url = "github:tlvince/ectool.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # # depend on the latest `atuin` in order to enable daemon mode
    # atuin = {
    #   url = "github:atuin-sh/atuin/main";
    #   inputs = {
    #     nixpkgs.follows = "nixpkgs";
    #     flake-utils.follows = "flake-utils";
    #   };
    # };
  };

  ############################################################################
  #### OUTPUTS ###############################################################
  outputs = { self, nixpkgs, nixos-hardware, home, utils, rust-overlay, ... }@inputs:
    let
      config = {
        allowUnfree = true;
        input-fonts.acceptLicense = true;
        # needed for Obsidian 1.4.16; this version of Electron is EOL but the nixpkgs
        # package for Obsidian hasn't been updated to a newer electron yet.
        #
        # TODO: remove this once https://github.com/NixOS/nixpkgs/issues/263764
        # is resolved...
        permittedInsecurePackages = [ "electron-26.3.0" ];
      };
      overlays = [
        (import ./pkgs/overlay.nix)
        rust-overlay.overlays.default
        # inputs.atuin.overlays.default
        # TODO(eliza): it would be nice if this was only added for the framework
        # system config...
        (_: prev: { fw-ectool = inputs.fw-ectool.packages.${prev.system}.ectool; })
      ];
    in
    {

      lib = import ./lib;

      ###########
      ## NixOS ##
      ###########
      nixosConfigurations = self.lib.genNixOSHosts {
        inherit inputs config overlays;

        baseModules = [
          utils.nixosModules.autoGenFromInputs
          self.nixosModules.default
          home.nixosModules.home-manager
        ];
      };

      nixosModules.default = import ./modules/nixos;

      ##################
      ## Home Manager ##
      ##################
      homeConfigurations = self.lib.genHomeHosts {
        inherit inputs config overlays;

        user = "eliza";

        baseModules = [ self.homeModules.default ];

      };

      homeModules.default = import ./modules/home;

    };
}
