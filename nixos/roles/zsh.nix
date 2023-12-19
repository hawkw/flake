{ config, lib, pkgs, ... }:

{
  programs.zsh.enable = true;
  # Enable ZSH completion for system packages
  environment.pathsToLink = [ "/share/zsh" ];
}
