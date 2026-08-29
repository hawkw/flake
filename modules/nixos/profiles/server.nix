# Configuration for server systems
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.server;
in
{
  options.profiles.server.enable = mkEnableOption "server defaults profile";

  config = mkIf cfg.enable {
    # Disable auto-suspend if gdm is installed.
    services.displayManager.gdm.autoSuspend = false;
    # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
    # If no user is logged in, the machine will power down after 20 minutes.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };

    # Allow passwordless sudo when connecting via ssh (we already auth'd via
    # public key, that's enough).
    #
    # We use `pam_rssh` instead of `pam_ssh_agent_auth`, which apparently does
    # not support ed25519 keys)
    #
    # When connecting via ssh, make sure to use `-A` or `-o ForwardAgent=yes`
    # to ensure the SSH agent is forwarded to this box.
    #
    # See https://discourse.nixos.org/t/nixos-rebuild-remote-deployments-non-root-pam/50477/19
    security.pam = {
      rssh = {
        enable = true;
        settings = {
          auth_key_file = "/etc/ssh/authorized_keys.d/$ruser";
          loglevel = "debug";
          cue = true;
        };
      };
      services.sudo.rssh = true;
    };
  };
}
