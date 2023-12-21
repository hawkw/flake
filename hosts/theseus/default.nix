{ nixos-hardware, ... }: {
  system = "x86_64-linux";

  modules =
    [ ./configuration.nix nixos-hardware.nixosModules.framework-13-7040-amd ];

  home.modules = [ ./home.nix ];
}
