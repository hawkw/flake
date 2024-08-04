{ config, lib, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {
  config = mkIf cfg.enable {
    programs.ssh.matchBlocks =
      let
        vpn = "vpn.eng.oxide.computer";
        jeeves = "jeeves";
        mkLabMachine = name: {
          host = name;
          hostname = "${name}.eng.oxide.computer";
          proxyJump = vpn;
          user = "eliza";
        };
        mkRacklette = { name, gzIp, switchZoneIp, }: (
          let all = "${name}-all"; in {
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
            "${name}wicket" = hm.dag.entryBefore [ all ] {
              host = "${name}wicket";
              hostname = "${switchZoneIp}%%${name}_sw1tp0";
              user = "wicket";
            };

            #
            # root in the switch zone:
            #
            "${name}switch" = hm.dag.entryBefore [ all ] {
              host = "${name}switch";
              hostname = switchZoneHostname;
            };

            #
            # gimlets by cubby number
            #
            ${name} = hm.dag.entryBefore [ all jeeves ] {
              host = "${name}gc*";
              proxyCommand = ''ssh ${jeeves} pilot -r ${name} tp nc any $(echo "%h" | sed s/${name}gc//) %p'';
              forwardAgent = true;
              proxyJump = vpn;
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
