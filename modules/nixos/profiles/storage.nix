# Configuration for storage systems (not filesystem-specific; see
# profiles/zfs.nix for zfs)
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.profiles.storage;
in
{
  options.profiles.storage = {
    enable = mkEnableOption "storage server profile";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      # various LSI SAS card thingies
      #
      # TODO(eliza): there could be a setting that's specifically for "there are
      # SAS drives", since some systems might just be SATA/NVMe...
      storcli2
      lsirec
      lsiutil
      lsscsi
      # seagate drive firmware utility
      openseachest
      sg3_utils
      # smartctl, for drive burn-in and periodic health checks
      smartmontools
    ];

    # Continuous drive-health monitoring via smartd.
    #
    # This is enabled even on ZFS-based storage systems, since smartd detects
    # pre-failure physical hardware health indicators, rather than corrupted
    # data detected by ZFS scrubs. It is also the only thing which will poll
    # idle hot-spare drives, so we don't discover that they're totally dead only
    # after they're swapped in.
    services.smartd = {
      # If a system wants to spin down drives, such as in very infrequently
      # written offsite backups, consider disabling smartd.
      enable = mkDefault true;
      # Flags:
      #    -a: default monitoring set
      #    -s: scheduled background self-tests
      # Timing:
      #    - short weekly (Sat 03:00),
      #    - long monthly (1st of the month at 04:00). This is intended to be
      #      offset from the  weekly scrub configured for ZFS systems.
      defaults.autodetected = mkDefault "-a -s (S/../../6/03|L/../01/./04)";
    };
  };
}
