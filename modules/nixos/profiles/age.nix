{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.age;
in
with lib;
{
  options.profiles.age = {
    enable = mkEnableOption "configuration for Age encryption";
  };

  config = mkIf cfg.enable (
    mkMerge [
      {
        environment.systemPackages = with pkgs; [ rage age-plugin-tpm ];
        age.rekey = {
          # The path to the master identity used for decryption. See the
          # option's description for more information.
          masterIdentities = [{
            identity = ../../../secrets/master-identities/1password-ssh.pub;
            pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICNWunZTkQnvkKi6gbeRfOXaIg4NL0OiE0SIXosxRP6s";
          }];
          storageMode = "local";
          # Choose a directory to store the rekeyed secrets for this host. This
          # cannot be shared with other hosts. Please refer to this path from
          # your flake's root directory and not by a direct path literal like
          # ./secrets
          localStorageDir = ../../.. + "/secrets/rekeyed/${config.networking.hostName}";

          # The path where all generated secrets should be stored by default. If
          # set, this automatically sets age.secrets.<name>.rekeyFile to a
          # default value in this directory, for any secret that defines a
          # generator.
          generatedSecretsDir = ../../.. + "/secrets/generated";
          agePlugins = with pkgs; [
            age-plugin-tpm
            age-plugin-1p
            _1password-cli

            age-plugin-tpm
          ];
        };
      }
      # If 1Password is enabled, add the 1password age plugin.
      (mkIf config.programs._1password.enable {
        environment.systemPackages = [ pkgs.age-plugin-1p ];
      })
    ]
  );
}
