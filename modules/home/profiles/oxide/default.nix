{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.oxide;
in
with lib; {

  options.profiles.oxide = {
    enable = mkEnableOption "personal configuration for Oxide utilities";
  };

  config =
    mkIf cfg.enable {
      home.packages = with pkgs;
        let
          atrium-sync = writeShellApplication
            {
              name = "atrium-sync";
              runtimeInputs = [ rsync ];
              text = builtins.readFile ./atrium-sync.sh;
            };
          atrium-run = writeShellApplication
            {
              name = "atrium";
              runtimeInputs = [ openssh rsync atrium-sync ];
              text = builtins.readFile ./atrium-run.sh;
            };
        in
        [ atrium-sync atrium-run ];

      # use Nix flake in the Omicron repo.
      programs.zsh.initExtra = ''
        export OMICRON_USE_FLAKE=1;
      '';

      home.sessionVariables = {
        # Tell direnv to opt in to using the Nix flake for Omicron.
        OMICRON_USE_FLAKE = " 1 ";
      };

      programs.ssh.matchBlocks =
        let
          proxyJump = "vpn.eng.oxide.computer,jeeves.eng.oxide.computer";
          switchZoneHostname = "fe80::aa40:25ff:fe05:602%%madrid_sw1tp0";
          extraOptions = {
            "StrictHostKeyChecking" = "no";
          };
        in
        {
          # madrid - global zone
          "madridgz" = {
            host = "madridgz";
            hostname = "fe80::eaea:6aff:fe09:7f66%%madrid_host0";
            user = "root";
            inherit proxyJump extraOptions;
          };
          # madrid - wicket on switch zone
          "madridwicket" = {
            host = "madridwicket";
            hostname = switchZoneHostname;
            user = "wicket";
            inherit proxyJump extraOptions;
          };
          # madrid - root on switch zone
          "madridswitch" = {
            host = "madridswitch";
            hostname = switchZoneHostname;
            user = "root";
            inherit proxyJump extraOptions;
          };
        };

      programs.oxide = {
        looker.enable = true;
        humility = {
          enable = true;
          environment =
            let
              basePath = "/home/eliza/Code/oxide/hubris/target";
            in
            {
              "gimletlet" = {
                probe = "0483:3754:000B00154D46501520383832";
                archive = "${basePath}/gimletlet/dist/default/build-gimletlet-image-default.zip";
              };
              "nucleo" = {
                probe = "0483:374e:0030003C3431511237393330";
                archive = "${basePath}/demo-stm32h753-nucleo/dist/default/build-demo-stm32h753-nucleo-image-default.zip";
              };
              "rot" = {
                probe = "1fc9:0143:53BKD0YYVRBPB";
                archive = {
                  "a" = "${basePath}/rot-carrier/dist/a/build-rot-carrier-image-a.zip";
                  "b" = "${basePath}/rot-carrier/dist/b/build-rot-carrier-image-b.zip";
                };
              };
            };
        };
      };
    };
}
