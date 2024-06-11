{
  description = "Eliza's NixOS and Home-Manager configuration flake";

  ############################################################################
  #### NIX CONFIG ############################################################
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };


  ############################################################################
  #### INPUTS ################################################################
  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs?ref=nixos-23.11";
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # deploy-rs: for remote deployments
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    home = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware/master";

    nixos-raspberrypi = {
      url = "github:ramblurr/nixos-raspberrypi";
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

    eclssd = {
      url = "https://flakehub.com/f/mycoliza/eclssd/0.1.64.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        rust-overlay.follows = "rust-overlay";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  ############################################################################
  #### OUTPUTS ###############################################################
  outputs = { self, nixpkgs, nixos-hardware, nixos-raspberrypi, home, utils, rust-overlay, deploy-rs, flake-parts, ... }@inputs:
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

        (_: prev: { eclssd = inputs.eclssd.packages.${prev.system}.eclssd; })
        # TODO(eliza): it would be nice if this was only added for the framework
        # system config...
        (_: prev: { fw-ectool = inputs.fw-ectool.packages.${prev.system}.ectool; })
      ];

      lib = import ./lib;
    in
    flake-parts.lib.mkFlake { inherit inputs; }
      {
        perSystem = { pkgs, system, ... }: with pkgs; with lib; {
          devShells.default = mkShell { buildInputs = [ deploy-rs.packages.${system}.default ]; };
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
              inputs.vu-server.nixosModules.default
              inputs.vupdaters.nixosModules.default
              inputs.eclssd.nixosModules.default
            ];
          };

          ####################
          ## NixOS modules ###
          ####################
          nixosModules.default = import ./modules/nixos;

          ####################
          ## NixOS (images) ##
          ####################
          images = {
            clavius =
              (self.nixosConfigurations.clavius.extendModules {
                modules = [
                  nixos-raspberrypi.nixosModules.sd-image-rpi3
                ];
              }).config.system.build.sdImage;
          };


          #####################
          ## deploy-rs nodes ##
          #####################
          deploy.nodes =
            let
              mkNode = { hostname, system ? "x86_64-linux", extraOpts ? { } }: {
                inherit hostname;
                profiles.system = ({
                  sshUser = "eliza";
                  path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${hostname};
                  user = "root";
                } // extraOpts);
              };
            in
            {
              clavius = {
                hostname = "clavius";
                profiles.system = {
                  sshUser = "eliza";
                  sshOpts = [ "-t" ];
                  path =
                    deploy-rs.lib.aarch64-linux.activate.nixos
                      self.nixosConfigurations.clavius;
                  user = "root";
                };
              };

              noctis = mkNode { hostname = "noctis"; };
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
