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
    _1password.enable = mkEnableOption "Enable 1Password CLI ssh scripts";
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
        ipmitool
      ];
    })
    ### 1password SSHpass helper ###
    (mkIf cfg._1password.enable {
      home.packages = with pkgs;
        let
          opssh = with pkgs; writeShellApplication {
            name = "opssh";
            runtimeInputs = [ sshpass ];
            text = ''
              if [ "$#" -lt 1 ]; then
                echo "Usage: $0 <HOST> [SSH_ARGS]"
                exit 1
              fi
              HOST="$1"
              SSHPASS=$(op read "op://Personal/$HOST/password")
              export SSHPASS
              sshpass -e ssh "$@"
            '';
          };
          opsync = with pkgs; writeShellApplication {
            name = "oprsync";
            runtimeInputs = [ sshpass rsync ];
            text = ''
              if [ "$#" -lt 1 ]; then
                echo "Usage: $0 <HOST> [RSYNC_ARGS]"
                exit 1
              fi
              HOST="$1"
              shift # consume hostname arg
              SSHPASS=$(op read "op://Personal/$HOST/password")
              USER=$(op read "op://Personal/$HOST/username")
              export SSHPASS
              rsync --rsh="sshpass -e ssh -l $USER" "$@"
            '';
          };
          opipmi = with pkgs; writeShellApplication {
            name = "opipmi";
            runtimeInputs = [ ipmitool ];
            text = ''
              if [ "$#" -lt 1 ]; then
                echo "Usage: $0 <HOST> [IPMI_ARGS]"
                exit 1
              fi
              NAME="$1"
              shift # consume hostname arg
              PASS=$(op read "op://Personal/$NAME/BMC password")
              USER=$(op read "op://Personal/$NAME/BMC username")
              HOST=$(op read "op://Personal/$NAME/BMC DNS name")
              ipmitool -I lanplus -H "$HOST" -U "$USER" -P "$PASS" "$@"
            '';
          };
        in
        [ opssh opipmi opsync ];
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
