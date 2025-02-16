{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.opstools;
in
with lib;
{

  options.profiles.opstools = {
    enable = mkEnableOption "Miscellaneous ops tools";
    net.enable = mkEnableOption "Enable networking ops tools";
    supermicro.enable = mkEnableOption "Enable Supermicro-specific IPMI tools.";
  };

  config = mkIf cfg.enable (mkMerge [
    ({
      home.packages = with pkgs; [
        ### SNMP ###
        net-snmp
        # useful for generating readable unique idents
        rust-petname
        ### IPMI ###
        freeipmi
      ];
    })
    ### networking tools ###
    (mkIf cfg.net.enable {
      home.packages = with pkgs; [
        nmap
        slurm
        bandwhich
        # assorted wiresharks
        termshark
        tcpdump
        # misc
        inetutils
        iperf
        iproute2
        whois
      ];
    })

    # If the destkop profile is enabled, enable GUI tools too
    (mkIf config.profiles.desktop.enable {
      home.packages = with pkgs; mkMerge [
        (mkIf cfg.net.enable [
          mtr-gui
          wireshark
        ])
        (mkIf cfg.supermicro.enable [
          ipmiview
        ])
      ];
    })

    ### Supermicro IPMI tools ###
    (mkIf cfg.supermicro.enable {
      home.packages = with pkgs;
        [
          ipmicfg
        ];
    })
  ]);
}
