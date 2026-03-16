{ config, pkgs, lib, ... }:
let
  cfg = config.services.rclone.mount;
in
with lib;
{
  options.services.rclone.mount = {
    enable = mkEnableOption "rclone remote mount user service";
    package = mkOption {
      type = types.package;
      default = pkgs.rclone;
      description = "The rclone package to use";
    };
    mountdir = mkOption {
      type = types.str;
      default = "~/mnt";
      description = "The directory to mount the remote to";
    };
    remotes = mkOption {
      type = types.listOf (types.str);
      default = [ ];
      description = "List of remote names to mount";
    };
  };

  config = mkIf cfg.enable {
    systemd.user.services =
      let
        mkRcloneService = remote: {
          "rclone-${remote}" = {
            Unit = {
              Description = "rclone: FUSE filesystem for remote ${remote}";
              Documentation = "man:rclone(1)";
              After = [ "network-online.target" ];
              Wants = [ "network-online.target" ];
            };
            Service = {
              Type = "notify";
              ExecStartPre = ''
                ${pkgs.coreutils}/bin/mkdir -p ${cfg.mountdir}/${remote}
              '';
              ExecStart = ''
                ${cfg.package}/bin/rclone mount \
                --config=%h/.config/rclone/rclone.conf \
                --vfs-cache-mode writes \
                --vfs-cache-max-size 100M \
                --umask 022 \
                --allow-other \
                --log-systemd \
                ${remote}: ${cfg.mountdir}/${remote}
              '';
              ExecStop =
                ''
                  /run/wrappers/bin/fusermount -u ${cfg.mountdir}/${remote}
                '';
            };
          };
        };
      in
      mkMerge (map mkRcloneService cfg.remotes);
  };
}
