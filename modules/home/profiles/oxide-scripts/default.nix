{ config, lib, pkgs, ... }:
let cfg = config.profiles.oxide-scripts;
in with lib; {
  options.profiles.oxide-scripts = {
    enable = mkEnableOption "Profile with shell scripts for syncing with Oxide lab hosts";
  };

  config = mkIf cfg.enable {
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
  };
}
