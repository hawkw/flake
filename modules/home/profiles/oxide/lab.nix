{ config, lib, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {
  config = mkIf cfg.enable {
    programs.ssh.matchBlocks =
      let
        jeeves = "jeeves";
        labNoVpn = "noVpn";
        engDomain = "eng.oxide.computer";
        mkLabMachine = name: hm.dag.entryBefore [ labNoVpn ] {
          host = name;
          hostname = "${name}.${engDomain}";
          user = "eliza";
        };
        mkRacklette =
          {
            # name of the racklet
            name
          , # yes, this looks like "gzip", but it's the global zone IP
            gzIp
            # IP of the switch zone
          , switchZoneIp
          }: (
            let
              all = "${name}-all";
              switchZoneHostname = "${switchZoneIp}%%${name}_sw1tp0";
              wicket = "${name}wicket";
              switch = "${name}switch";
              gc = "${name}gc";
            in
            {
              #
              # root in the global zone of the scrimlet:
              #
              "${name}gz" = hm.dag.entryBefore [ all ] {
                host = "${name}gz";
                hostname = "${gzIp}%%${name}_host0";
              };

              #
              # Wicket in the switch zone:
              #
              ${wicket} = hm.dag.entryBefore [ all ] {
                host = wicket;
                hostname = switchZoneHostname;
                user = "wicket";
              };

              #
              # root in the switch zone:
              #
              switch = hm.dag.entryBefore [ all ] {
                host = switch;
                hostname = switchZoneIp;
              };

              #
              # gimlets by cubby number
              #
              gc = hm.dag.entryBefore [ all jeeves ] {
                host = "${gc}*";
                proxyCommand = ''ssh ${jeeves} pilot -r ${name} tp nc any $(echo "%h" | sed s/${gc}//) %p'';
                forwardAgent = true;
                extraOptions = {
                  ServerAliveInterval = "15";
                };
              };

              #
              # config applied to all of the above:
              #
              "${name}-all" = hm.dag.entryBefore [ jeeves ] {
                host = "${name}*";
                user = "root";
                proxyJump = jeeves;
                extraOptions = {
                  # Every time the racklet is reset, the host key changes, so
                  # silence all  of openssh's warnings that "SOMEONE MIGHT BE
                  # DOING SOMETHING NASTY".
                  StrictHostKeyChecking = "no";
                  UserKnownHostsFile = "/dev/null";
                  LogLevel = "error";
                };
              };
            }
          );
      in
      ### lab machines
      (attrsets.genAttrs [ jeeves "atrium" "cadbury" "yuban" "lurch" ] mkLabMachine)
      # if the Oxide VPN connection is *not* active, add a `proxyJump` to
      # connect to the VPN first. Don't do this if already on the VPN,
      # because it makes the SSH connection take longer to establish.
      // {
        ${labNoVpn} = {
          match = ''host "!vpn.${engDomain}, *.${engDomain}" !exec "nmcli con show --active | grep 'oxide.*vpn'"'';
          proxyJump = "vpn.${engDomain}";
        };
      }

      ### racklette: madrid
      // mkRacklette {
        name = "madrid";
        gzIp = "fe80::eaea:6aff:fe09:7f66";
        switchZoneIp = "fe80::aa40:25ff:fe05:602";
      }

      ### racklette: london
      // mkRacklette {
        name = "london";
        gzIp = "fe80::eaea:6aff:fe09:8567";
        switchZoneIp = "fe80::aa40:25ff:fe05:702";
      };

  };
}
