{ config, lib, pkgs, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {

  imports = [ ./lab.nix ];

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
          lookall = writeShellApplication {
            name = "lookall";
            runtimeInputs = [ openssh ];
            text = builtins.readFile ./lookall.sh;
          };
        in
        [ atrium-sync atrium-run lookall ];

      # use Nix flake in the Omicron repo.
      programs.zsh.initExtra = ''
        export OMICRON_USE_FLAKE=1;
      '';

      home.sessionVariables = {
        # Tell direnv to opt in to using the Nix flake for Omicron.
        OMICRON_USE_FLAKE = " 1 ";
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
