{ config, lib, pkgs, ... }:
let
  cfg = config.programs.oxide;
in
with lib; {

  options.programs.oxide = {
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
      environment = mkOption
        {
          description = "Generates a Humility environment file.";
          type = with types;
            attrsOf (submodule {
              options = {
                probe = mkOption {
                  type = strMatching ''[0-9a-fA-F]{4}:[0-9a-fA-F]{4}:.+'';
                  description = "The probe ID for this target.";
                  example = "0483:374e:002A00174741500520383733";
                };
                archive = mkOption {
                  type = either (attrsOf path) path;
                  description = "Archive path(s) for this target";
                  example = "/gimlet/hubris/archives/grimey/build-gimlet.zip";
                };
              };
            });
          default = { };
        };
    };
  };

  config = mkMerge [
      {}
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
      (mkIf cfg.humility.enable (mkMerge [
        {
          home.packages = [ (pkgs.callPackage ./humility.nix { }) ];
        }
        (mkIf (cfg.humility.environment != { }) {
          xdg.configFile."humility/environment.json".text = builtins.toJSON cfg.humility.environment;
          programs.zsh.initExtra = ''
            export HUMILITY_ENVIRONMENT=${config.xdg.configHome}/humility/environment.json;
          '';
          home.sessionVariables = {
            HUMILITY_ENVIRONMENT = "${config.xdg.configHome}/humility/environment.json";
          };
        })
      ]))
    ];
}
