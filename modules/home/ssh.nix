{ config, osConfig, lib, pkgs, ... }:
let
  _1passwordAgent = {
    enable = config.programs._1password-gui.enableSshAgent;
    path = "${config.home.homeDirectory}/.1password/agent.sock";
  };
  cfg = config.profiles.ssh;

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

  # From the NixOS config, the list of Wake-on-LAN targets, and the systems
  # configured as SSH WoL relays (see modules/nixos/profiles/wake-on-lan.nix).
  wolTargets = osConfig.profiles.wakeOnLan.targets or { };
  # True if this host is configured as a Wake-on-LAN SSH relay client. If it is,
  # then it has the ssh keys installed to use with the WoL relays. Without
  # relays, `ssh-wol` only works while on the same LAN as the target.
  wolClient = osConfig.profiles.wakeOnLan.client.enable or false;

  # A shell script run as a `ProxyCommand` that wakes a host with a Wake-on-LAN
  # magic packet if its SSH port isn't reachable, waits for sshd to come up, and
  # then relays the connection.
  #
  # This is implemented as a `ProxyCommand` rather than a `Match exec`, because
  # `Match exec` runs whenever the config is parsed, which would include `ssh -G`
  # and hostname canonicalization. A `ProxyCommand` runs only when ssh actually
  # opens a new transport, which is when the target should actually be woken.
  #
  # stdout is the SSH transport, so all diagnostics go to stderr.
  #
  # Because a WoL magic packet is an L2 broadcast, sending one directly only
  # works when the client is on the same LAN as the target. This is where the
  # SSH relaying scheme described in `nixos/profiles/wake-on-lan.nix` comes in:
  # if other always-on systems on the same LAN are configured as WoL relays, the
  # script attempts to use them to send the magic packet to the target until one
  # succeeds. This way, the target can be woken even if the client is not on the
  # same LAN, as long as a relay is reachable. Multiple relays may be specified
  # for redundancy in case some relays are unavailable.
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
        echo "ssh-wol: $host:$port is unreachable, sending magic packet to $mac" >&2
        if ! wakeonlan "$mac" >&2; then
          echo "ssh-wol: local broadcast failed" >&2
        fi

        wake_via_relay() {
          # The relay's authorized_keys entry forces the wake command, so no
          # command is sent. `-n`, which prevents SSH from reading from stdin,
          # is necessary here, because this script's stdin is the SSH transport
          # intended for the *target*, which should not be forwarded to the
          # relay. `-F none` prevents this command from running with the user's
          # SSH config (agents, other identities, ProxyCommands). `-T` skips pty
          # allocation, which would fail anyway without a terminal.
          if ssh -n -T -F none \
              -o BatchMode=yes \
              -o ConnectTimeout=5 \
              -o IdentitiesOnly=yes \
              -o IdentityAgent=none \
              -i "$relay_key" \
              "wol@$1" >&2; then
            echo "ssh-wol: asked $1 to wake $mac" >&2
          else
            echo "ssh-wol: waking via $1 failed (ssh exited $?)" >&2
          fi
        }

        # Fire off an attempt to wake via every relay concurrently, in the
        # background. This is intended to reduce the latency with which the host
        # is woken in the case where one or more relays are not available. If we
        # did this sequentially, the attempt to wake via a relay that's down
        # will wait out its connect timeout before trying the next one. Having
        # extra magic packets flying around is harmless, so this is fine.
        relay_pids=()
        if [ "$#" -gt 0 ] && [ ! -r "$relay_key" ]; then
          echo "ssh-wol: SSH relay key $relay_key is not readable! cannot wake via relays" >&2
        else
          for relay in "$@"; do
            wake_via_relay "$relay" &
            relay_pids+=("$!")
          done
        fi

        start=$SECONDS
        until nc -z -w 1 "$host" "$port" 2>/dev/null; do
          if [ $((SECONDS - start)) -ge "$timeout_secs" ]; then
            echo "ssh-wol: $host:$port still unreachable ''${timeout_secs}s after sending a wake-on-LAN packet. giving up!" >&2
            exit 1
          fi
          sleep 0.25
        done
        echo "ssh-wol: $host:$port is up after $((SECONDS - start))s" >&2
        # The host is up, so any relays still trying no longer matter.
        if [ "''${#relay_pids[@]}" -gt 0 ]; then
          kill "''${relay_pids[@]}" 2>/dev/null || true
        fi
      fi

      exec nc "$host" "$port"
    '';
  };
in
with lib;
{
  options =
    let
      # Option type for an SSH duration string in the format specified in
      # sshd_config(5):
      # https://man7.org/linux/man-pages/man5/sshd_config.5.html#TIME_FORMATS
      #
      # TODO(eliza): a fancier regex could enforce that the duration is given in
      # descending order (e.g. "1d2h3m", not "3m2h1d"), and that units are not
      # repeated. AFAICT, OpenSSH SSH will accept weirder duration strings, but
      # they're harder to interpret when reading the config...
      sshDuration = types.strMatching "([0-9]+[sSmMhHdDwW]?)+";
    in
    {
      profiles.ssh.defaults = {
        controlMaster = {
          enable = mkEnableOption ''
            SSH ControlMaster by default for all sessions
          '';
          persist = mkOption {
            type = with types; either bool sshDuration;
            description = ''
              How long to keep the ControlMaster socket open after all sessions
              have ended.

              This should either be a duration or a boolean. Durations are
              specified in [the syntax described in `sshd_config(5)`][1].
              If `true`, the socket will persist indefinitely, and if `false`,
              it will be closed immediately after the session ends. If this is a
              duration, it will be closed after the specified time has elapsed,
              unless a new session is started.

              [1]:
                https://man7.org/linux/man-pages/man5/sshd_config.5.html#TIME_FORMATS
            '';
            default = "10m";
            example = "1h30s";
          };
          # TODO(eliza): make the socket path configurable?
        };
        serverKeepalive = {
          enable = mkEnableOption ''
            "sending keepalive messages to the server.

            If this is disabled, connections to unresponsive servers will never
            be closed."
          '' // {
            # Enable server keepalive by default.
            #
            # The hekate suspend + WoL stuff doesn't play nicely with
            # ServerAliveInterval=0, since the host suspnding makes the
            # session hang, and Zed's ssh remote thingy seems to pool ssh
            # ControlMaster connections, rather than reconnecting every
            # time, which results in it trying to use a stuck ControlMaster
            # rather than reconnect.
            #
            # TODO(eliza): if/when changing the WoL config to use
            # wake-on-unicast + ARP caching, this can (and should!) go away,
            # so that input into a n idle session just wakes.
            default = true;
          };
          interval = mkOption {
            type = sshDuration;
            description = ''
              The interval at which to send keepalive messages to the server.

              This sets the default value of `ServerAliveInterval` for * in the
              SSH configuration.

              For example, if this is `15s` and
              {option}\home.profiles.ssh.defaults.serverKeepalive.countMax``
              is `3`, then a connection to an unresponsive server will be
              closed after about 45 seconds.
            '';
            default = "15s";
            example = "10s";
          };
          countMax = mkOption {
            type = types.ints.positive;
            description = ''
              The maximum number of missed keepalive messages before the
              connection is closed.

              This sets the default value of `ServerAliveCountMax` for * in the
              SSH configuration.

              For example, if this is `3` and
              {option}\home.profiles.ssh.defaults.serverKeepalive.interval``
              is 15 seconds, then a connection to an unresponsive server will be
              closed after about 45 seconds.
            '';
            default = 3;
          };
        };
      };
      programs._1password-gui.enableSshAgent =
        mkEnableOption "Enable 1Password SSH Agent";
    };

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
              wolTargets
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
                HashKnownHosts = false;
                UserKnownHostsFile = "~/.ssh/known_hosts";

                # Defaults are potentially enabled by the
                # `defaults.controlMaster.enable` option.
                ControlMaster = mkDefault false;
                ControlPath = "$XDG_RUNTIME_DIR/ssh/sockets/%r@%n:%p";
                ControlPersist = mkDefault false;

                # Defaults are potentially overridden by the
                # `defaults.serverKeepalive.enable` option.
                ServerAliveInterval = mkDefault 0;
                ServerAliveCountMax = mkDefault 0;
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

        # Default ControlMaster settings.
        (mkIf cfg.defaults.controlMaster.enable {
          settings."*" = {
            ControlMaster = "auto";
            ControlPersist = cfg.defaults.controlMaster.persist;
          };
        })

        # Default ServerAliveInterval and ServerAliveCountMax settings.
        (mkIf (cfg.defaults.serverKeepalive.enable) {
          settings."*" = {
            ServerAliveInterval = cfg.defaults.serverKeepalive.interval;
            ServerAliveCountMax = cfg.defaults.serverKeepalive.countMax;
          };
        })
      ];
  };
}
