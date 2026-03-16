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
      type = types.path;
      default = "~/mnt";
      description = "The directory to mount the remote to";
    };
    remotes = mkOption {
      type = types.listOf (types.str);
      default = [ ];
      description = "List of remote names to mount";
    };
  };

  config =
    let
      mkRcloneService = { remote }: {
        systemd.services.user."rclone-${remote}" = {
          description = "rclone: FUSE filesystem for remote ${remote}";
          documentation = "man:rclone(1)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          script = "${cfg.package}/bin/rclone mount";
          scriptArgs = ''
            --config=%h/.config/rclone/rclone.conf \
            --vfs-cache-mode writes \
            --vfs-cache-max-size 100M \
            --umask 022 \
            --allow-other \
            --log-systemd \
            ${remote}: ${cfg.mountdir}/${remote}
          '';
          preStart = ''
            ${pkgs.coreutils}/bin/mkdir -p ${cfg.mountdir}/${remote}
          '';
          postStop = ''
            /run/wrappers/bin/fusermount -u ${cfg.mountdir}/${remote}
          '';
          serviceConfig = {
            Type = "notify";
          };
        };
      };
    in
    mkIf cfg.enable (map (remote: mkRcloneService { inherit remote; }) cfg.remotes);
}
