{
  description = "Eliza's NixOS and Home-Manager configuration flake";

  ############################################################################
  #### NIX CONFIG ############################################################
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.garnix.io"
      # "https://cosmic.cachix.org/"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      # "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE="
    ];
  };

  ############################################################################
  #### INPUTS ################################################################
  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs?ref=nixos-24.11";
    # nixpkgs-stable.follows = "nixos-cosmic/nixpkgs-stable";
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    # NOTE:change "nixpkgs" to "nixpkgs-stable" to use stable NixOS release
    # nixpkgs.follows = "nixos-cosmic/nixpkgs";

    # nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";
    flake-utils.url = "github:numtide/flake-utils";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # for building Rust packages
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    # deploy-rs: for remote deployments
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    # declarative disk partitioning
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware/master";

    nixos-raspberrypi = {
      url = "github:hawkw/nixos-raspberrypi?ref=eliza/no-noXlibs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixos-hardware.follows = "nixos-hardware";
      };
    };

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
        rust-overlay.follows = "rust-overlay";
      };
    };

    # for secureboot support on theseus
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";

      # Optional but recommended to limit the size of your system closure.
      inputs = {
        nixpkgs.follows = "nixpkgs";
        rust-overlay.follows = "rust-overlay";
        flake-parts.follows = "flake-parts";
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

    eclssd = {
      # url = "github:hawkw/eclssd/6de42a256f547bba72bda5274b3d42dc574676e8";
      url = "https://flakehub.com/f/mycoliza/eclssd/0.1.118.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        rust-overlay.follows = "rust-overlay";
        flake-utils.follows = "flake-utils";
      };
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    # Nix formatter in Rust
    alejandra = {
      url = "github:kamadorueda/alejandra/3.1.0";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    lix-module = {
      url = "https://git.lix.systems/lix-project/nixos-module/archive/2.93.2-1.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  ############################################################################
  #### OUTPUTS ###############################################################
  outputs =
    { self
    , nixpkgs
    , nixos-hardware
    , nixos-raspberrypi
    , home
    , utils
    , rust-overlay
    , deploy-rs
    , flake-parts
    , lix-module
    , ...
    }@inputs:
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

        # add alejandra package
        (_: prev: { alejandra = inputs.alejandra.defaultPackage.${prev.system}; })
        # add ghostty package
        (_: prev: { ghostty = inputs.ghostty.packages.${prev.system}.ghostty; })
        # add ECLSSD
        (_: prev: { eclssd = inputs.eclssd.packages.${prev.system}.eclssd; })
        # add fw-ectool package
        # TODO(eliza): it would be nice if this was only added for the framework
        # system config...
        (_: prev: { fw-ectool = inputs.fw-ectool.packages.${prev.system}.ectool; })
      ];

      lib = import ./lib;
    in
    flake-parts.lib.mkFlake { inherit inputs; }
      {
        perSystem = { pkgs, system, ... }: with pkgs; with lib; {
          devShells.default = mkShell {
            buildInputs = [
              deploy-rs.packages.${system}.default
              inputs.disko.packages.${system}.disko
            ];
          };
        };
        flake = {
          ###########
          ## NixOS ##
          ###########
          nixosConfigurations = lib.genNixOSHosts {
            inherit inputs config overlays self;

            baseModules = [
              utils.nixosModules.autoGenFromInputs
              self.nixosModules.default
              home.nixosModules.home-manager
              lix-module.nixosModules.lixFromNixpkgs
              inputs.vu-server.nixosModules.default
              inputs.vupdaters.nixosModules.default
              inputs.eclssd.nixosModules.default
              inputs.disko.nixosModules.disko
              # inputs.nixos-cosmic.nixosModules.default
            ];
          };

          ####################
          ## NixOS modules ###
          ####################
          nixosModules.default = import ./modules/nixos;

          ####################
          ## NixOS (images) ##
          ####################
          images =
            let
              mkPiImage = { hostname, imageKind ? "sd-image-rpi3" }:
                (self.nixosConfigurations.${hostname}.extendModules {
                  modules = [
                    nixos-raspberrypi.nixosModules.${imageKind}
                  ];
                }).config.system.build.sdImage;
            in
            {
              clavius = mkPiImage { hostname = "clavius"; };
              tycho = mkPiImage { hostname = "tycho"; };
            };


          #####################
          ## deploy-rs nodes ##
          #####################
          deploy.nodes =
            let
              mkNode = { hostname, domain ? ".sys.home.elizas.website", system ? "x86_64-linux", extraOpts ? { } }: {
                hostname = "${hostname}${domain}";
                profiles.system = ({
                  sshUser = "eliza";
                  path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${hostname};
                  user = "root";
                } // extraOpts);
              };
            in
            {
              clavius = mkNode {
                hostname = "clavius";
                system = "aarch64-linux";
                extraOpts = { sshOpts = [ "-t" ]; };
              };

              tycho = mkNode {
                hostname = "tycho";
                system = "aarch64-linux";
                extraOpts = { sshOpts = [ "-t" ]; };
              };

              noctis = mkNode { hostname = "noctis"; };

              tereshkova = mkNode { hostname = "tereshkova"; };

              hekate = mkNode { hostname = "hekate"; };
            };


          ##################
          ## Home Manager ##
          ##################
          homeConfigurations = lib.genHomeHosts {
            inherit inputs config overlays;

            user = "eliza";

            baseModules = [ self.homeModules.default ];

          };

          homeModules.default = import ./modules/home;

          ################
          ## checks ######
          ################
          checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
        };

        systems = [ "x86_64-linux" "aarch64-linux" ];
      };
}
