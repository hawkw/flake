# Configuration to enable TPM on machines that have one.
{ lib, config, pkgs, ... }:
let cfg = config.profiles.tpm;
in with lib; {
  options.profiles.tpm = { enable = mkEnableOption "TPM profile"; };

  config = mkIf cfg.enable (
    let
      tss = "tss";
      uhid = "uhid";
      tpmRules = pkgs.writeTextFile {
        name = "tpm-udev-rules";
        text = ''
          # tpm devices can only be accessed by the tss user but the tss
          # group members can access tpmrm devices
          KERNEL=="tpm[0-9]*", TAG+="systemd", MODE="0660", OWNER="${tss}"
          KERNEL=="tpmrm[0-9]*", TAG+="systemd", MODE="0660", OWNER="${tss}", GROUP="${tss}"

          # uhid group can access /dev/uhid
          KERNEL=="${uhid}", SUBSYSTEM=="misc", MODE="0660", GROUP="${uhid}"
        '';
        destination = "/etc/udev/rules.d/99-tpm.rules";
      };

    in
    {
      boot.kernelModules = [ uhid ];

      users.groups.tss.name = tss;
      users.groups.uhid.name = tss;

      users.users.eliza.extraGroups = [ tss uhid ];

      services.udev.packages = [ tpmRules ];
    }
  );
}
