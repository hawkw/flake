{ config, pkgs, lib, ... }:

let cfg = config.profiles.nix-tools;
in with lib; {
  options.profiles.nix-tools = {
    enable = mkEnableOption "Miscellaneous Nix tools";
    enableNomAliases = mkEnableOption "Enable aliasing `nix` to nix-output-monitor";
  };

  config =
    let
      collectPathArgs = ''
        paths=()
        while [ "$#" -gt 0 ]; do
          arg="$1"
          [[ "$arg" =~ ^--?.+ ]] && break
          paths+=("$arg"); shift
        done
      '';
      pathArgs = ''"''${paths[@]}"'';
      collectFlakeFlags = ''
        flakeFlags=()
        while [ "$#" -gt 0 ]; do
          arg="$1"
          case "$arg" in
            ${
              builtins.concatStringsSep "|" [
                "build"
                "bundle"
                "copy"
                "daemon"
                "derivation"
                "develop"
                "doctor"
                "edit"
                "eval"
                "flake"
                "fmt"
                "hash"
                "help"
                "help-stores"
                "key"
                "log"
                "nar"
                "path-info"
                "print-dev-env"
                "profile"
                "realisation"
                "registry"
                "repl"
                "run"
                "search"
                "shell"
                "show-config"
                "store"
                "upgrade-nix"
                "why-depends"
              ]
            })
              break
              ;;
            *)
              flakeFlags+=("$arg"); shift
              ;;
          esac
        done
      '';
      flakeFlags = ''"''${flakeFlags[@]}"'';
      nixNomArgs = "--log-format internal-json --verbose";
      nixBuildCmdWithNomArgs = buildCmd: ''
        ${collectPathArgs}
        ${buildCmd} ${pathArgs} ${nixNomArgs} "$@"
      '';
      nixShellCmdWithNomArgs = shellCmd: ''
        ${shellCmd} ${nixNomArgs} "$@"
      '';
      nixStoreCmdWithNomArgs = storeCmd: ''
        operation="$1"; shift
        case "$operation" in
          --realise|-r)
            ${collectPathArgs}
            ${storeCmd} "$operation" ${pathArgs} ${nixNomArgs} "$@"
            ;;
          *)
            ${storeCmd} "$operation" "$@"
            ;;
        esac
      '';
      nixWithNomArgs = nix:
        pkgs.symlinkJoin {
          name = "nix-with-nom-args-${nix.version}";
          paths = (lib.attrsets.mapAttrsToList pkgs.writeShellScriptBin {
            nix = ''
              program="$(basename $0)"
              case "$program" in
                nix)
                  ${collectFlakeFlags}
                  command="$1"; shift
                  case "$command" in
                    build)
                      ${nixBuildCmdWithNomArgs "${nix}/bin/nix ${flakeFlags} build"}
                      ;;
                    shell)
                      ${nixShellCmdWithNomArgs "${nix}/bin/nix ${flakeFlags} shell"}
                      ;;
                    store)
                      ${nixStoreCmdWithNomArgs "${nix}/bin/nix ${flakeFlags} store"}
                      ;;
                    *)
                      ${nix}/bin/nix ${flakeFlags} "$command" "$@"
                      ;;
                  esac
                  ;;
                *)
                  "${nix}/bin/$program" "$@"
                  ;;
              esac
            '';
            nix-build = nixBuildCmdWithNomArgs "${nix}/bin/nix-build";
            nix-shell = nixShellCmdWithNomArgs "${nix}/bin/nix-shell";
            nix-store = nixStoreCmdWithNomArgs "${nix}/bin/nix-store";
          }) ++ [ nix ];
        };
      nixNomPkgs = { nix ? null, nixos-rebuild ? null, home-manager ? null }:
        lib.attrsets.mapAttrs pkgs.writeShellScriptBin ((if nix != null then {
          nix = ''
            program="$(basename $0)"
            case "$program" in
              nix)
                ${collectFlakeFlags}
                command="$1"; shift
                case "$command" in
                  build|shell|develop)
                    ${pkgs.nix-output-monitor}/bin/nom ${flakeFlags} "$command" "$@"
                    ;;
                  *)
                    ${nix}/bin/nix ${flakeFlags} "$command" "$@"
                    ;;
                esac
                ;;
              *)
                "${nix}/bin/$program" "$@"
                ;;
            esac
          '';
          nix-build = ''
            ${pkgs.nix-output-monitor}/bin/nom-build "$@"
          '';
          nix-shell = ''
            ${pkgs.nix-output-monitor}/bin/nom-shell "$@"
          '';
          nix-store = ''
            ${nixWithNomArgs nix}/bin/nix-store "$@" \
              |& ${pkgs.nix-output-monitor}/bin/nom --json
          '';
        } else
          { }) // (if nixos-rebuild != null then {
          nixos-rebuild = ''
            ${pkgs.expect}/bin/unbuffer \
              ${
                nixos-rebuild.override (old: { nix = nixWithNomArgs old.nix; })
              }/bin/nixos-rebuild "$@" \
              |& ${pkgs.nix-output-monitor}/bin/nom --json
          '';
        } else
          { }) // (if home-manager != null then {
          home-manager = ''
            PATH="${nixWithNomArgs pkgs.nix}/bin:$PATH" \
              ${pkgs.expect}/bin/unbuffer \
              ${home-manager}/bin/home-manager "$@" \
              |& ${pkgs.nix-output-monitor}/bin/nom --json
          '';
        } else
          { }));
      nomAliases = pkgs:
        lib.attrsets.mapAttrs (name: pkg: "${pkg}/bin/${name}") (nixNomPkgs pkgs);
    in
    mkIf cfg.enable
      (mkMerge [
        {
          home.packages = with pkgs; [
            alejandra
            nil
            nixpkgs-fmt
            nix-output-monitor
          ];

          programs.nix-index.enable = lib.mkDefault true;

          # this conflicts with `nix-index`, which is nicer imo
          # command-not-found.enable = true;
        }
        (mkIf cfg.enableNomAliases {
          # see https://github.com/maralorn/nix-output-monitor/issues/108
          home.shellAliases =
            nomAliases { inherit (pkgs) nix nixos-rebuild home-manager; };
        })
        (mkIf config.programs.zsh.enable {
          programs.nix-index.enableZshIntegration = true;
        })
      ])
  ;
}
