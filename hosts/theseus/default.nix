{ nixos-hardware, lanzaboote, vu-server, ... }: {
  system = "x86_64-linux";

  modules = [
    ./configuration.nix
    nixos-hardware.nixosModules.framework-13-7040-amd
    lanzaboote.nixosModules.lanzaboote
    vu-server.nixosModules.default
  ];

  home.modules = [ ./home.nix ];
}
