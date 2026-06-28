{ config, pkgs, lib, ... }:
let
  cfg = config.profiles.age;
in
with lib;
{
  options.profiles.age =
    {
      enable = mkEnableOption "configuration for Age encryption";

      tpmHostIdentity = {
        enable = mkEnableOption ''
          decryption of this host's agenix secrets with a TPM-sealed age
          identity (via `age-plugin-tpm`), rather than with its SSH host key.

          This is suitable for use on hosts where the SSH host key is not usable
          by age (i.e. because it also lives in the TPM), or on hosts where the
          SSH host key would be stored in plaintext (i.e. systems with unencrypted
          root file systems).  With this setting enabled, secret decryption gets
          its own TPM-bound age identity at `/etc/age/host-identity.txt`, which
          keeps secrets decryptable only on this host's TPM.

          The identity file is generated automatically on first boot by the
          `age-host-identity` systemd service if it does not already exist. After
          it is generated you must read back its recipient and set it as
          `age.rekey.hostPubkey`, then `agenix rekey` and rebuild. The recipient
          cannot be derived at evaluation time because the key is sealed to the
          running host's TPM.'';
      };
    };

  config = mkIf cfg.enable (
    mkMerge [
      {
        environment.systemPackages = with pkgs;
          [ rage age-plugin-tpm ];
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
          # 1Password's plugins (`age-plugin-1p` + `_1password-cli`) are added
          # conditionally below, only on hosts where 1Password is enabled.
          agePlugins = with pkgs; [
            age-plugin-tpm
          ];
        };

        # The agenix activation script decrypts secrets with a minimal PATH that
        # excludes `environment.systemPackages`, so upstream `age` cannot find
        # plugin binaries when a host decrypts with a plugin-based identity,
        # such as `age-plugin-tpm`. Using `age.rekey.agePlugins` only puts
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
      # TPM-sealed *age* host identity. Opt-in per host via `profiles.age.tpm`.
      (mkIf cfg.tpmHostIdentity.enable {
        # Point decryption at the TPM identity stub. The stub only *references*
        # the TPM-sealed key (the secret never leaves the TPM); setting this,
        # rather than relying on the SSH-host-key default, also clears the
        # `age.identityPaths must be set` assertion.
        age.identityPaths = [ "/etc/age/host-identity.txt" ];

        # Generate the identity on first boot if the host does not already have
        # one. The key is sealed to this machine's TPM, so it cannot be
        # generated ahead of time on the build host; it must be created on the
        # target. The `ConditionPathExists` guard makes this a one-shot
        # bootstrap that never clobbers an existing identity.
        #
        # This only mints the identity. The admin still has to read back its
        # recipient, set it as `age.rekey.hostPubkey`, `agenix rekey`, and
        # rebuild --- the recipient is build-time input and cannot be known
        # until the key exists. Until then, secret-dependent services fail to
        # start, but the host still boots.
        systemd.services.age-host-identity = {
          description = "Generate the TPM-sealed age host identity";
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathExists = "!/etc/age/host-identity.txt";
          path = [ pkgs.age-plugin-tpm ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            install -d -m 0700 /etc/age
            age-plugin-tpm --generate -o /etc/age/host-identity.txt
            chmod 0600 /etc/age/host-identity.txt
            echo "generated a new TPM-sealed age identity at /etc/age/host-identity.txt"
            echo "its recipient is:"
            # Use --tpm-recipient so the recipient carries the age1tpm1 prefix
            # rather than age1tag1; agenix-rekey resolves the plugin from the
            # prefix and there is no age-plugin-tag binary.
            age-plugin-tpm -y /etc/age/host-identity.txt --tpm-recipient
          '';
        };
      })
      # If 1Password is enabled, add the 1Password age plugins. The master
      # identity lives in 1Password, so these are only needed where 1Password
      # is enabled --- in particular the host you run `agenix rekey` from.
      # Scoping them here keeps `_1password-cli` (and an aarch64 build of it)
      # out of the closures of hosts that never touch 1Password, e.g. the Pis.
      # `agenix rekey` still gets `_1password-cli` for decrypting the master
      # identity, because its aggregate ageWrapper unions every host's plugins
      # and picks it up from a 1Password-enabled host (the rekey controller).
      (mkIf config.programs._1password.enable {
        environment.systemPackages = [ pkgs.age-plugin-1p ];
        age.rekey.agePlugins = with pkgs; [ age-plugin-1p _1password-cli ];
      })
    ]
  );
}
