{ nixos-hardware, ... }: {
  system = "x86_64-linux";

  modules =
    [ ./configuration.nix nixos-hardware.nixosModules.framework.amd-7040 ];

  home.modules = [ ./home.nix ];
}
