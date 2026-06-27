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
          ];
        };

        # The agenix activation script decrypts secrets with a minimal PATH that
        # excludes `environment.systemPackages`, so upstream `age` cannot find
        # plugin binaries when a host decrypts with a plugin-based identity,
        # such as `age-plugin-tpm``. Using `age.rekey.agePlugins` only puts
        # plugins on PATH for the rekeying step, not for host-side activation
        # (see oddlama/agenix-rekey#154 and #155). Wrap `age` so the configured
        # plugins are on its PATH at runtime too.
        age.ageBin = getExe (pkgs.writeShellApplication {
          name = "age-wrapped";
          runtimeInputs = with pkgs; [ age ] ++ config.age.rekey.agePlugins;
          text = ''
            exec age "$@"
          '';
        });
      }
      # If 1Password is enabled, add the 1password age plugin.
      (mkIf config.programs._1password.enable {
        environment.systemPackages = [ pkgs.age-plugin-1p ];
      })
    ]
  );
}
