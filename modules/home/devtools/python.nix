{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [ python39Packages.pip ];
}
