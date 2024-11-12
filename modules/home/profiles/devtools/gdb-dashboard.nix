{ config, lib, pkgs, ... }:

with lib;
let
  gdbinitPkg = { stdenv, lib, pkgs }:
    stdenv.mkDerivation {
      pname = "gdb-dashboard";
      version = "latest";

      src = pkgs.fetchFromGitHub {
        owner = "cyrus-and";
        repo = "gdb-dashboard";
        rev = "101cf69cc95f90956b6d9612a3468dac6422c87c";
        sha256 = "145c9y7wj3mi34k3y2isvs3v4k7mmiyn6lc477m8hhc9js1q2ia4";
      };

      phases = "installPhase";

      installPhase = ''
        set +x
        mkdir -p $out
        cp -v $src/.gdbinit $out/.gdbinit
      '';

      meta = with lib; {
        description = "Modular visual interface for GDB in Python";
        homepage = "https://github.com/cyrus-and/gdb-dashboard";
        license = licenses.mit;
      };
    };
  cfg = config.programs.gdb.dashboard;
in
{
  options.programs.gdb.dashboard = {
    enable = mkEnableOption "dashboard";

    enablePygments = mkEnableOption "pygments" // {
      description = "whether to enable Pygments syntax highlighting";
    };

    extraConfig = mkOption {
      default = "";
      type = types.lines;
      description = ''
        Extra user configuration that should be added to <filename>$XDG_CONFIG_HOME/gdb-dashboard</filename>.
        See <a href="https://github.com/cyrus-and/gdb-dashboard/wiki/Use-personal-configuration-files">
        the documentation</a> for details.
      '';
      example = ''
        dashboard -layout assembly breakpoints expressions history memory registers source stack threads variables
        dashboard registers -style column-major True
        dashboard registers -style list 'rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 rip eflags cs ss ds es fs gs fs_base gs_base k_gs_base cr0 cr2 cr3 cr4 cr8 efe msxr'
      '';
    };

    gdbPackage = mkOption {
      type = types.package;
      default = pkgs.gdb;
      defaultText = literalExample "pkgs.gdb";
      description = "The package to use for gdb.";
    };

  };

  config = mkIf cfg.enable {

    home.packages = mkMerge [
      (mkIf cfg.enablePygments [ pkgs.python312Packages.pygments ])
      [ cfg.gdbPackage ]
    ];

    home.file.".gdbinit".text =
      let pkg = pkgs.callPackage gdbinitPkg { };
      in builtins.readFile "${pkg}/.gdbinit";

    xdg.configFile."gdb-dashboard/extraConfig".text = cfg.extraConfig;
  };
}
