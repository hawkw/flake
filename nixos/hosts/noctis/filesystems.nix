{ config, pkgs, lib, ... }:

{
  system.stateVersion = "22.11";

  boot = {
    supportedFilesystems = [ "zfs" "xfs" ];
    kernelParams = [ "elevator=none" ];
    zfs.enableUnstable = true;
  };

  # ZFS configuration
  services.zfs = {
    # Enable TRIM
    trim.enable = true;
    # Enable automatic scrubbing and snapshotting.
    autoScrub.enable = true;
    autoSnapshot = {
      enable = true;
      frequent = 4;
      daily = 3;
      weekly = 2;
      monthly = 2;
    };
  };

  fileSystems."/" = {
    device = "nvme-pool/system/root";
    fsType = "zfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-id/nvme-ADATA_SX8100NP_2J4620041364-part1";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "nvme-pool/local/nix";
    fsType = "zfs";
  };

  fileSystems."/home/eliza" = {
    device = "nvme-pool/home/eliza";
    fsType = "zfs";
  };

  fileSystems."/root" = {
    device = "nvme-pool/home/root";
    fsType = "zfs";
  };

  fileSystems."/var/lib/docker" = {
    device = "/dev/zvol/nvme-pool/system/docker";
    fsType = "xfs";
  };

  swapDevices = [ ];
}
