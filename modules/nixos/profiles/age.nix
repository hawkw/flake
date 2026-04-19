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
        environment.systemPackages = [ pkgs.rage ];
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
          agePlugins = [ pkgs.age-plugin-1p pkgs._1password-cli ];
        };
      }
      # If 1Password is enabled, add the 1password age plugin.
      (mkIf config.programs._1password.enable {
        environment.systemPackages = [ pkgs.age-plugin-1p ];
      })
    ]
  );
}
