{ lanzaboote, ... }: {
  system = "x86_64-linux";

  modules = [
    ./configuration.nix
    # Secure Boot (configured in ./configuration.nix).
    lanzaboote.nixosModules.lanzaboote
  ];

  home.modules = [ ./home.nix ];
}
