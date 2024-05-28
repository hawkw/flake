{ nixos-hardware, lanzaboote, ... }: {
  system = "x86_64-linux";

  modules = [
    ./configuration.nix
    nixos-hardware.nixosModules.framework-13-7040-amd
    lanzaboote.nixosModules.lanzaboote
  ];

  home.modules = [ ./home.nix ];
}
