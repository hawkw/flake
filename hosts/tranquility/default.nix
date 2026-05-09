{ ... }: {
  system = "x86_64-linux";

  modules = [
    ./configuration.nix
  ];

  home.modules = [ ./home.nix ];
}
