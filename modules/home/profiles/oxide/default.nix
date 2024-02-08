{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.oxide;
in
with lib; {
  options.profiles.oxide = {
    enable = mkEnableOption "Profile with various Oxide stuff";
  };

  config = mkIf cfg.enable
    {
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
          looker = with pkgs;
            let
              pname = "looker";
              rev = "173a93c92ac78068569b252d3ec8a1cef4be1de6";
              src = fetchFromGitHub {
                owner = "oxidecomputer";
                repo = pname;
                inherit rev;
                hash = "sha256-V5hnr3e+GyxejcQSoqo+R/2tAXM3mfUtXR2ezKKVV7Q=";
              };
            in
            rustPlatform.buildRustPackage {
              inherit src pname;
              version = rev;
              cargoLock = {
                lockFile = "${src}/Cargo.lock";
              };
            };
        in
        [ atrium-sync atrium-run looker ];
      programs.zsh.initExtra = ''
        export OMICRON_USE_FLAKE=1;
      '';
      home.sessionVariables = {
        # Tell direnv to opt in to using the Nix flake for Omicron.
        OMICRON_USE_FLAKE = " 1 ";
      };
    };
}

