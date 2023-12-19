{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.logid;
  configFile = "logid.cfg";
  configPath = "/etc/${configFile}";

  # keypressAction = types.attrsOf {
  #   keys = mkOption {
  #     type = types.listOf types.str;
  #     description = ''
  #       A required string/integer array/list field that defines the keys to be
  #       pressed/released. For a list of key/button strings, refer to
  #       linux/input-event-codes.h. (e.g. keys: ["KEY_A", "KEY_B"];).
  #       Alternatively, you may use integer keycodes to define the keys.

  #       Please note that these event codes work in a US (QWERTY) keyboard layout.
  #       If you have a locale set that does not use this keyboard layout, please
  #       map it to whatever key it would be on a QWERTY keyboard. (e.g. "KEY_Z"
  #       on a QWERTZ layout should be "KEY_Y")
  #     '';
  #     example = ''["KEY_A", "KEY_B"]'';
  #   };
  # };

  # deviceOpts = { name, config, ...}: {
  #   options = {
  #     name = mkOption {
  #       type = types.str;
  #       readOnly = true;
  #       description = ''
  #         This is a required string field that defines the name of the device.

  #         To get the name of the device, launch logid with the device connected and it should print out a message with the device name. (e.g. name: "MX Master";)
  #       '';
  #       example = "Wireless Mouse MX Master";
  #     };

  #     buttons = mkOption {
  #       type = types.listOf (types.submodule {
  #           cid = mkOption {
  #             type = types.str;
  #             example = "0xc4";
  #             description = "This is a required integer field that defines the Control ID of the button that is being remapped.";
  #           };
  #           action = 
  #       });
  #     };
  #   };
  # }
in {
  options = {
    services.logid = {
      enable =
        mkEnableOption "logiops, a driver for Logitech mice and keyboards";

      package = mkOption {
        default = (pkgs.callPackage ./logiops.nix { });
        defaultText = "pkgs.logiops";
        example = "pkgs.logiops";
        type = types.package;
        description = ''
          Logiops package to use.
        '';
      };

      # TODO(eliza): allow specifiying config as nix expressions

      extraConfig = mkOption {
        type = types.str;
        default = "";
        description = ''
          Additional LogiOps config as a string. This is appended to the end of the `logid.cfg` file.

          If this is unset, the example config file is used.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.logid = {
      wantedBy = [ "multi-user.target" ];
      description = "Logitech Configuration Daemon";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/logid";
        User = "root";
        ExecReload = "/run/current-system/sw/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
      };
    };

    environment.etc."${configFile}".source = if cfg.extraConfig != "" then
      pkgs.writeText cfgPath cfg.extraConfig
    else
      "${cfg.package}/logid.example.cfg";
  };
}
