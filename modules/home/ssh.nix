{ config, osConfig, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };

  # SSH identities for provisioned YubiKeys (see lib/yubikeys.nix). The key
  # handles live in ~/.ssh on machines they've been copied to.
  yubikeys = import ../../lib/yubikeys.nix { inherit lib; };
  # Generate SSH config blocks setting `IdentityFile` for yubikey-backed SSH
  # keys.
  #
  # These have a `Match exec` clause that checks for the presence of the
  # corresponding Yubikey (via the symlinks we set up in
  # `nixos/profiles/yubikey.nix`). This way, we only offer the key from the
  # Yubikey that's actually present, which stops ssh from printing a bunch of
  # junk complaining that it tried to offer *all* the yubikey-backed SK keys and
  # two of them didn't work. This is not strictly necessary (ssh still
  # ultimately *works* if it offers the not-present keys) but i didn't love that
  # it printed a bunch of complaints.
  yubikeyIdentityBlocks = lib.mapAttrs'
    (serial: key:
      lib.nameValuePair "yubikey-present-${serial}" {
        header = ''Match exec "test -e /dev/yubikey/${serial}"'';
        IdentityFile = "~/.ssh/${key.privkeyFilename}";
        # Restrict ssh to only offer the identity file for the present Yubikey.
        # This prevents SSH from offering all SK keys (including those for the
        # not-physically-connected Yubikeys), which results in printing errors
        # that it can't use those keys.
        #
        # IdentitiesOnly is only set when we *did* find a physically present
        # yubikey. Otherwise, it would also prevent offering forwarded keys when
        # SSHed into a remote system, where /dev/yubikey/$SERIAL doesn't exist.
        IdentitiesOnly = "yes";
      })
    yubikeys.ssh.bySerial;

  # Wake-on-LAN targets, and their relays (see lib/wol.nix).
  wol = import ../../lib/wol.nix { inherit lib; };
  # Whether this host has the relay keys installed. Without them, `ssh-wol`
  # only broadcasts locally, which works on the LAN but not over the tunnel.
  wolClient = osConfig.profiles.wol.client.enable or false;

  # `ProxyCommand` that wakes a host with a Wake-on-LAN magic packet if its SSH
  # port isn't reachable, waits for sshd to come up, and then relays the
  # connection.
  #
  # This is a `ProxyCommand` rather than a `Match exec`, because `Match exec`
  # runs whenever the config is parsed (including `ssh -G`, and twice under
  # hostname canonicalization). A `ProxyCommand` runs only when ssh actually
  # opens a new transport.
  #
  # stdout is the SSH transport, so all diagnostics go to stderr.
  #
  # The magic packet is an L2 broadcast, so a local broadcast only works from
  # the target's LAN. If relays are given, the script also asks them (always-on
  # hosts on that LAN) to broadcast it, in order, stopping at the first that
  # succeeds. This works from anywhere a relay is reachable. No failure here is
  # fatal on its own: whether the target came up is decided by the wait loop.
  sshWol = pkgs.writeShellApplication {
    name = "ssh-wol";
    runtimeInputs = with pkgs; [ netcat-openbsd openssh wakeonlan ];
    text = ''
      if [ "$#" -lt 3 ] || [ "$#" -eq 4 ]; then
        echo "usage: ssh-wol <mac> <host> <port> [<relay-key> <relay-host>...]" >&2
        exit 2
      fi
      mac="$1" host="$2" port="$3"
      shift 3
      relay_key="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi
      # A cold boot from S5 includes server-board POST, which is slow.
      timeout_secs=300

      if ! nc -z -w 1 "$host" "$port" 2>/dev/null; then
        echo "ssh-wol: $host:$port unreachable; sending magic packet to $mac" >&2
        if ! wakeonlan "$mac" >&2; then
          echo "ssh-wol: local broadcast failed" >&2
        fi

        if [ "$#" -gt 0 ] && [ ! -r "$relay_key" ]; then
          echo "ssh-wol: relay key $relay_key is not readable; not waking via relays" >&2
        elif [ "$#" -gt 0 ]; then
          for relay in "$@"; do
            # The relay's authorized_keys entry forces the wake command, so no
            # command is sent. `-n` is load-bearing: this script's stdin is the
            # outer SSH transport, which the inner ssh must not consume.
            # `-F none` keeps the user's config (agents, other identities,
            # ProxyCommands) out of it; host keys are still checked against
            # known_hosts.
            if ssh -n -F none \
                -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o IdentitiesOnly=yes \
                -o IdentityAgent=none \
                -i "$relay_key" \
                "wol@$relay" >&2; then
              echo "ssh-wol: asked $relay to wake $mac" >&2
              break
            else
              echo "ssh-wol: waking via $relay failed (ssh exited $?)" >&2
            fi
          done
        fi

        start=$SECONDS
        until nc -z -w 1 "$host" "$port" 2>/dev/null; do
          if [ $((SECONDS - start)) -ge "$timeout_secs" ]; then
            echo "ssh-wol: $host:$port still unreachable ''${timeout_secs}s after wake; giving up" >&2
            exit 1
          fi
          sleep 2
        done
        echo "ssh-wol: $host:$port is up after $((SECONDS - start))s" >&2
      fi

      exec nc "$host" "$port"
    '';
  };
in
with lib;
{
  options.programs._1password-gui.enableSshAgent =
    mkEnableOption "Enable 1Password SSH Agent";

  config = {
    home.packages = with pkgs; [ ssh-tools ];
    programs.ssh =
      mkMerge [
        {
          enable = true;
          # `enableDefaultConfig` is deprecated; the equivalent defaults are
          # set manually in `settings."*"` below.
          enableDefaultConfig = false;
          settings =
            let
              homeHosts = [ "hekate" "noctis" "tranquility" "tereshkova" ];
              noctis = "noctis";
              noctis-tailscale = "${noctis}-tailscale";
              sysdomain = "sys.home.elizas.website";
            in
            {
              # "${noctis}-local" = hm.dag.entryBefore [ noctis-tailscale ] {
              #   header = ''Match host ${noctis} exec "ping -c1 -W1 -q ${noctis}.local"'';
              #   HostName = "noctis.local";
              # };
              ${noctis-tailscale} = hm.dag.entryBefore [ "notSsh" ] {
                header = "Host ${noctis}";
                HostName = noctis;
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

              # The attribute name already equals the `Host` pattern, so the
              # `header` is derived as `Host hekate`.
              homeAliases = hm.dag.entryBefore [ "sysdomain" ] {
                header = "Host ${concatStringsSep " " homeHosts}";
                HostName = "%h.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

              sysdomain = hm.dag.entryBefore [ "notSsh" ] {
                header = "Host *.${sysdomain}";
                ForwardAgent = true;
                AddKeysToAgent = true;
              };

            } // mapAttrs'
              (name: target: nameValuePair "${name}-wol" (hm.dag.entryBefore [ "homeAliases" ] {
                header = "Host ${name} ${name}.${sysdomain}";
                ProxyCommand = concatStringsSep " " ([ (getExe sshWol) target.mac "%h" "%p" ]
                ++ optionals wolClient (
                  [ osConfig.age.secrets.${target.relayKey.secretName}.path ]
                  ++ map (relay: "${relay}.${sysdomain}") target.relays
                ));
              }))
              wol.targets
            // {
              "*" = {
                # Settings previously provided by
                # `programs.ssh.enableDefaultConfig`, which has been deprecated.
                ForwardAgent = false;
                # With the 1P agent, adds are refused, so "yes" is inert at
                # best. With the keyring agent, "yes" is necessary to load a
                # YubiKey key handle on first use.
                AddKeysToAgent = if _1passwordAgent.enable then "no" else "yes";
                Compression = false;
                ServerAliveInterval = 0;
                ServerAliveCountMax = 3;
                HashKnownHosts = false;
                UserKnownHostsFile = "~/.ssh/known_hosts";
                ControlMaster = false;
                ControlPath = "~/.ssh/master-%r@%n:%p";
                ControlPersist = false;
              };
            };
        }
        (mkIf _1passwordAgent.enable {
          settings."notSsh" = {
            header = ''Match host * exec "test -z $SSH_CONNECTION"'';
            IdentityAgent = _1passwordAgent.path;
          };
        })

        # If 1Password agent is not in use, add the Yubikey identity blocks
        # generated above. Since these set `IdentitiesOnly`, they would break
        # the 1Password agent and should only be added if it's not in use.
        (mkIf (!_1passwordAgent.enable) {
          settings = yubikeyIdentityBlocks;
        })
      ];
  };
}
