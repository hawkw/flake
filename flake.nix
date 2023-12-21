{
  description = "Eliza's NixOS and Home-Manager configuration flake";

  ############################################################################
  #### INPUTS ################################################################
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-23.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs?ref=nixos-unstable";

    home = {
      url = "github:nix-community/home-manager?ref=release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware/master";

    utils.url = "github:gytis-ivaskevicius/flake-utils-plus/v1.4.0";
  };

  ############################################################################
  #### OUTPUTS ###############################################################
  outputs = { self, nixpkgs, nixos-hardware, home, utils, ... }@inputs:
    let
      config = {
        allowUnfree = true;
        input-fonts.acceptLicense = true;
        # needed for Obsidian 1.4.16; this version of Electron is EOL but the nixpkgs
        # package for Obsidian hasn't been updated to a newer electron yet.
        # 
        # TODO: remove this once https://github.com/NixOS/nixpkgs/issues/263764
        # is resolved...
        permittedInsecurePackages = [ "electron-25.9.0" ];
      };
      overlays = [ (import ./pkgs/overlay.nix) ];
    in {

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
