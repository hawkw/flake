{ lib, pkgs, config, ... }:
let cfg = config.profiles.zfs; in with lib; {
  options.profiles.zfs = {
    enable = mkEnableOption "ZFS profile";
  };

  config = mkIf cfg.enable (
    let
      isUnstable = config.boot.zfs.package == pkgs.zfsUnstable;
      zfsCompatibleKernelPackages = lib.filterAttrs
        (
          name: kernelPackages:
            (builtins.match "linux_[0-9]+_[0-9]+" name) != null
            && (builtins.tryEval kernelPackages).success
            && (
              (!isUnstable && !kernelPackages.zfs.meta.broken)
              || (isUnstable && !kernelPackages.zfs_unstable.meta.broken)
            )
        )
        pkgs.linuxKernel.packages;
      latestZfsKernel = lib.last (
        lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
          builtins.attrValues zfsCompatibleKernelPackages
        )
      );
    in
    {
      boot = {
        # Note this might jump back and worth as kernel get added or removed.
        kernelPackages = latestZfsKernel;
        supportedFilesystems = [ "zfs" ];
        kernelParams = [ "elevator=none" ];
      };

      # ZFS configuration
      services.zfs = {
        # Enable TRIM
        trim.enable = mkDefault true;
        # Enable automatic scrubbing and snapshotting.
        autoScrub.enable = mkDefault true;
        autoSnapshot = {
          enable = mkDefault true;
          frequent = mkDefault 4;
          daily = mkDefault 3;
          weekly = mkDefault 2;
          monthly = mkDefault 2;
        };
        zed.enableMail = false;
      };

    }
  );
}
