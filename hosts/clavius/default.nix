{ nixos-hardware, nixos-raspberrypi, ... }: {
  system = "aarch64-linux";

  modules = [
    ./configuration.nix
    nixos-hardware.nixosModules.raspberry-pi-4
    nixos-raspberrypi.nixosModules.base
  ];

  # home.modules = [ ./home.nix ];
}
