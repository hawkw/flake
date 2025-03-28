{ ... }:

{

  boot.supportedFilesystems = [ "zfs" "xfs" "ext4" ];

  fileSystems."/" = {
    device = "nvme-pool/system/root";
    fsType = "zfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-id/nvme-Sabrent_17A807051DBE02076339-part1";
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

  # zvols formatted with other filesystems to run software that doesn't like
  # zfs:
  #
  # 1. xfs zvol for docker, because k3d volume mounts don't behave nicely on a
  #    zfs volume
  fileSystems."/var/lib/docker" = {
    device = "/dev/zvol/nvme-pool/system/docker";
    fsType = "xfs";
  };
  # 2. ext4 zvol for atuin; see: https://github.com/atuinsh/atuin/issues/952
  fileSystems."/home/eliza/.local/share/atuin" =
    {
      device = "/dev/zvol/nvme-pool/home/atuin";
      fsType = "ext4";
    };

  # swapDevices = [
  #   {
  #     device = "/dev/disk/by-id/nvme-ADATA_SX8100NP_2J4620041364-part2";
  #     randomEncryption.enable = true;
  #   }
  # ];
}
