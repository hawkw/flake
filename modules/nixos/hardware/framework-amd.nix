# NixOS module for Framework AMD laptops
#
# See also the `nixos-hardware` modules for Framework:
# https://github.com/NixOS/nixos-hardware/blob/33a97b5814d36ddd65ad678ad07ce43b1a67f159/framework/README.md

{ lib, config, pkgs, ... }:
let cfg = config.hardware.framework-amd;
in with lib; {

  options.hardware.framework-amd = {
    enable = mkEnableOption "Framework laptop profile";
  };

  config = mkIf cfg.enable
    {
      environment.systemPackages = with pkgs; [
        fprintd
        fw-ectool
      ];

      ### enable services ###
      services = {
        # use `fwupdmgr` for updating Framework firmware
        fwupd.enable = mkDefault true;

        # For fingerprint support
        fprintd.enable = mkDefault true;

        # AMD has better battery life with PPD over TLP:
        # https://community.frame.work/t/responded-amd-7040-sleep-states/38101/13
        #
        # NOTE: the `power-profiles-daemon` version that has nice framework AMD
        # support is currently only in `nixos-unstable` (my flake currently is
        # pointed at unstable, but please bear this in mind if you're copying my
        # configs.)
        power-profiles-daemon.enable = mkDefault true;
      };

      # enable the TPM profile
      hardware.tpm.enable = mkDefault true;

      ### misc hardware support tweaks ###

      boot.kernelParams = [
        # Disable AMD GPU scatter-gather buffer.
        # this (hopefully) fixes white screen issues when driving a thunderbolt
        # display. see here for details:
        # https://community.frame.work/t/tracking-graphical-corruption-in-fedora-39-amd-3-03-bios/39073/52
        "amdgpu.sg_display=0"
      ];

      # necessary to enable 802.11ax for the MEDIATEK WiFi chipset, as per:
      # https://community.frame.work/t/framework-nixos-linux-users-self-help/31426/77
      hardware.wirelessRegulatoryDatabase = true;
      # NOTE: you probably want to change this if you're in an 802.11
      # regulatory domain other than the US?
      boot.extraModprobeConfig = ''
        options cfg80211 ieee80211_regdom="US"
      '';
    };

}
