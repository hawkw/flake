{ vu-server, vupdaters, ... }: {
  system = "x86_64-linux";

  modules = [
    ./configuration.nix
    vu-server.nixosModules.default
    vupdaters.nixosModules.default
 ];

  home.modules = [ ./home.nix ];
}
