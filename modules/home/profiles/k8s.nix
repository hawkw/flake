# kubernetes`
{ config, pkgs, lib, ... }:

let cfg = config.profiles.k8s;
in {
  options.profiles.k8s = with lib; {
    enable = mkEnableOption "kubernetes profile";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; let
      k3d-import-all = writeShellApplication {
        name = "k3d-import-all";
        runtimeInputs = [ k3d docker ];
        text = ''
          docker images "$1" --format "{{.Repository}}:{{.Tag}}" | xargs k3d image import
        '';
      };
    in
    [
      kubectl
      kubespy
      # kube3d
      k3d
      k3d-import-all
      kubectx
      kubelogin
      azure-cli
      k9s
      stern
      kubernetes-helm
      step-cli
    ];

    programs.zsh = {
      shellAliases = { k = "kubectl"; };

    };
  };
}
