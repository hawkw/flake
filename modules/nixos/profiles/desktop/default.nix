# Profile for desktop machines (i.e. not servers).
{ config, lib, pkgs, ... }:
let cfg = config.profiles.desktop;
in {

  imports = [ ./gnome3.nix ./kde.nix ];

  options.profiles.desktop = with lib; {
    enable = mkEnableOption "Profile for desktop machines (i.e. not servers)";
  };

  config = lib.mkIf cfg.enable {
    # Use latest kernel by default.
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    ### pipewire ###
    # Use PipeWire as the system audio/video bus
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };
      jack.enable = true;
      pulse.enable = true;
      socketActivation = true;
    };

    ### services ###

    services = {
      # Enable the X11 windowing system.
      xserver = with lib; {
        enable = mkDefault true;

        # Configure keymap in X11
        xkb = {
          layout = mkDefault "us";
          variant = mkDefault "";
        };
      };

      # Enable CUPS to print documents.
      printing.enable = lib.mkDefault true;

    };

    ### systemd user session ###

    # Bound how long a logout can take, because a slow logout blocks re-login.
    #
    # When the last session for a user ends, the per-user systemd manager
    # (user@.service) shuts down, stopping every unit it owns, including the
    # app-*.scope units that desktop environments launch applications into. One
    # application ignoring SIGTERM will keep the logout from succeeding for
    # `TimeoutStopSec` seconds, which defaults to 90s. While that transaction is
    # queued, logind cannot start a new session for the same user, so login
    # attempts sit at the display manager with a spinner until the timeout
    # expires and the straggler is SIGKILLed. This is annoying.
    #
    # This dropin sets a 5-second timeout for all app-*.scope units via
    # systemd's truncated unit-name matching (systemd.unit(5)), so only launched
    # applications (not daemons) get the shorter timeout.
    #
    # GNOME and flatpak already ship `app-gnome-.scope.d` and
    # `app-flatpak-.scope.d` drop-ins setting TimeoutStopSec=5s, so 5s seems
    # like a reasonable default for interactive applications. And, because
    # dropins are applied based on filename ordering, setting a larger timeout
    # here would also increase the timeout for GNOME apps.
    systemd.user.units."app-.scope" = {
      text = ''
        [Scope]
        TimeoutStopSec=5s
      '';
      # `overrideStrategy = "asDropin"` makes the unit generator emit this as
      # `app-.scope.d/overrides.conf` rather than as a unit file named
      # `app-.scope`, which wouldn't work.
      overrideStrategy = "asDropin";
    };

    ### hardware ###
    hardware = {
      bluetooth.enable = lib.mkDefault true;
      ergodox.enable = lib.mkDefault true;
    };

    ### programs ###
    programs = {
      # Enable 1password and 1password-gui
      _1password.enable = true;
      _1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "eliza" ];
      };

      firefox.enable = true;
    };

  };
}
