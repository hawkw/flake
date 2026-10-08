{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.devtools.sccache;
in
with lib;
{
  options.profiles.devtools.sccache = {
    enable = mkEnableOption "sccache compilation cache";
    package = mkPackageOption pkgs "sccache";
    baseDirs = mkOption {
      type = types.envVar;
      example = "/home/my/project:/home/my/other/project";
      default = "";
      description = ''
        Sets the value of the SCCACHE_BASEDIRS environment variable.

        See https://github.com/mozilla/sccache#normalizing-paths-with-sccache_basedirs
        for more details.
      '';
    };
    cacheDir = mkOption {
      type = with types; nullOr str;
      example = "$XDG_CACHE_HOME/sccache";
      default = null;
      description = ''
        Sets the cache directory for sccache. If unset, sccache will use its
        default cache directory ($HOME/.cache/sccache on Linux).
      '';
    };
    cacheSize = mkOption {
      type = with types; nullOr (strMatching "[0-9]+[KMGT]?");
      example = "100G";
      default = null;
      description = ''
        Sets the maximum cache size (the value of the SCCACHE_CACHE_SIZE env
        variable).

        If this is unset, the default cache size (10GB) will be used.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.sessionVariables = mkMerge [
      { RUSTC_WRAPPER = "${cfg.package}/bin/sccache"; }
      (mkIf (cfg.baseDirs != "") { SCCACHE_BASEDIRS = cfg.baseDirs; })
      (mkIf (cfg.cacheSize != null) { SCCACHE_CACHE_SIZE = cfg.cacheSize; })
      (mkIf (cfg.cacheDir != null) { SCCACHE_DIR = cfg.cacheDir; })
    ];
  };


}
