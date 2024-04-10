# Configuration to enable TPM on machines that have one.
{ lib, config, pkgs, ... }:
let cfg = config.hardware.tpm;
in with lib; {
  options.hardware.tpm = { enable = mkEnableOption "TPM2 profile"; };

  config = mkIf cfg.enable (
    let
      tss = "tss";
      uhid = "uhid";
    in
    {
      security.tpm2 = {
        enable = true;
        tssUser = tss;
        tssGroup = tss;
        applyUdevRules = true;
        abrmd.enable = true;
        pkcs11.enable = true;
      };
      boot.kernelModules = [ uhid ];
      users.users.eliza.extraGroups = [ tss uhid ];

      environment.systemPackages = with pkgs; [ tpm2-tools tpm2-tss tpm2-abrmd ];
    }
  );
}
