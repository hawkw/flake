{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.oxide;
in
with lib; {

  options.profiles.oxide = {
    enable = mkEnableOption "Profile with various Oxide stuff";
    looker = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable Looker, a Bunyan log viewer";
      };
    };
    humility = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable Humility, the Hubris debugger.";
      };
    };
  };

  config =
    mkIf cfg.enable (mkMerge [
      # scripts and env vars
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
          in
          [ atrium-sync atrium-run ];
        programs.zsh.initExtra = ''
          export OMICRON_USE_FLAKE=1;
        '';
        home.sessionVariables = {
          # Tell direnv to opt in to using the Nix flake for Omicron.
          OMICRON_USE_FLAKE = " 1 ";
        };
      }
      # looker package
      (mkIf cfg.looker.enable (
        let
          looker = with pkgs;
            let
              pname = "looker";
              rev = "173a93c92ac78068569b252d3ec8a1cef4be1de6";
              src = fetchFromGitHub
                {
                  owner = "oxidecomputer";
                  repo = pname;
                  inherit rev;
                  hash = "sha256-V5hnr3e+GyxejcQSoqo+R/2tAXM3mfUtXR2ezKKVV7Q=";
                };
            in
            rustPlatform.buildRustPackage
              {
                inherit src pname;
                version = rev;
                cargoLock = {
                  lockFile = "${src}/Cargo.lock";
                };
              };
        in
        { home.packages = [ looker ]; }
      ))
      # humility package
      (mkIf cfg.humility.enable
        (
          {
            home.packages = [ (pkgs.callPackage ./humility.nix { }) ];
          }
        ))
    ]);
}
