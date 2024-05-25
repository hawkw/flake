# Configuration for ARM cross-compilation from x86
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.arm-cross-dev;
in
{
  options.profiles.arm-cross-dev.enable = mkEnableOption "ARM cross-compilation";

  config = mkIf cfg.enable {
    nix = {
      binaryCaches = [ "https://arm.cachix.org/" ];
      binaryCachePublicKeys = [ "arm.cachix.org-1:5BZ2kjoL1q6nWhlnrbAl+G7ThY7+HaBRD9PZzqZkbnM=" ];
    };

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  };
}
