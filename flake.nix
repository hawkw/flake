{
  description = "One Big Flake";

  ############################################################################
  #### INPUTS ################################################################
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-23.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager?ref=release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-unstable.url = "github:nix-community/home-manager";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
  };

  ############################################################################
  #### OUTPUTS ###############################################################
  outputs = { self, nixpkgs, home-manager, ... }@inputs: {

    nixosConfigurations = {
      noctis = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nixos/hosts/noctis/default.nix
          home-manager.nixosModules.home-manager
          { _module.args = { inherit inputs; }; }
        ];
      };
    };

    homeManagerConfigurations = {
      "eliza@noctis" = home-manager.lib.homeManagerConfiguration {
        configuration = ./home/machines/noctis.nix;
      };
    };

  };
}
