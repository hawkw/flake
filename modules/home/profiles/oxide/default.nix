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
        sp3-uart = {
          enable = true;
          # logDir = "/var/log";
        };
        humility = {
          enable = true;
          environment =
            let
              basePath = "/home/eliza/Code/oxide/hubris/target";
              sn17 = "sn17";
            in
            {
              ${sn17} = {
                probe = "0483:3754:003200124741500820383733";
                archive = "/gimlet/hubris/archives/build-gimlet-b-dev-image-default.zip";
                cmds = {
                  power = {
                    on = "humility -t ${sn17} hiffy -c Sequencer.set_state -a state=A0";
                    off = "humility -t ${sn17} hiffy -c Sequencer.set_state -a state=A2";
                    state = "humility -t ${sn17} hiffy -c Sequencer.get_state";
                  };
                  console = ''/bin/sh -c "sp3-uart /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_BG00RVDP-if00-port0"'';
                };
              };
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
