# Configuration for ARM cross-compilation from x86
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.arm-cross-dev;
in
{
  options.profiles.arm-cross-dev.enable = mkEnableOption "ARM cross-compilation";

  config = mkIf cfg.enable {
    nix.settings = {
      substituters = [ "https://arm.cachix.org/" ];
      trusted-public-keys = [ "arm.cachix.org-1:5BZ2kjoL1q6nWhlnrbAl+G7ThY7+HaBRD9PZzqZkbnM=" ];
    };

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
    # Use a statically-linked qemu so the binfmt registration carries the `F`
    # (fix-binary) flag. Without this, the interpreter is registered as a path
    # (`/run/binfmt/aarch64-linux`, flag `P`) that the kernel resolves at exec
    # time. That fails inside Nix's build sandbox, since it doesn't bind-mount
    # `/run/binfmt`.
    boot.binfmt.preferStaticEmulators = true;
  };
}
