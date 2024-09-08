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
        all-racklettes = "all-racklettes";
        racklette-gimlets = "racklette-gimlets";
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
              switchZoneHostname = "${switchZoneIp}%%${name}_sw1tp0";
              wicket = "${name}wicket";
              switch0 = "${name}switch0";
              switch1 = "${name}switch1";
              switch = "${name}switch";
              brm = "${name}BRM";
            in
            {
              #
              # root in the global zone of the scrimlet:
              #
              "${name}gz" = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                host = "${name}gz";
                hostname = "${gzIp}%%${name}_host0";
              };

              #
              # Wicket in the switch zone:
              #
              ${wicket} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                host = wicket;
                hostname = switchZoneHostname;
                user = "wicket";
              };

              #
              # root in the switch 0 zone:
              #
              ${switch0} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                host = switch0;
                extraOptions = {
                  ProxyCommand = "pilot -r ${name} tp nc 0 %p";
                };
              };

              #
              # root in the switch 1 zone:
              #
              ${switch1} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                host = switch1;
                extraOptions = {
                  ProxyCommand = "pilot -r ${name} tp nc 1 %p";
                };
              };

              #
              # root in the switch 1 zone:
              #
              ${switch} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                host = switch;
                extraOptions = {
                  ProxyCommand = "pilot -r ${name} tp nc 1 %p";
                };
              };

              ${brm} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ]
                {
                  host = "${brm}*";
                  extraOptions = {
                    ProxyCommand = ''pilot -r ${name} tp nc any $(echo %h | sed 's/^${name}//' | tr "[:lower:]" "[:upper:]") %p'';
                  };
                };
            }
          );
        labMachines = [ jeeves "atrium" "cadbury" "yuban" "lurch" "alfred" ];
        racklettes = [
          # racklette: madrid
          {
            name = "madrid";
            gzIp = "fe80::eaea:6aff:fe09:7f66";
            switchZoneIp = "fe80::aa40:25ff:fe05:602";
          }
          # racklette: london
          {
            name = "london";
            gzIp = "fe80::eaea:6aff:fe09:8567";
            switchZoneIp = "fe80::aa40:25ff:fe05:702";
          }
        ];
        rackletteNames = attrsets.catAttrs "name" racklettes;
      in
      {
        #
        # oxide lab machines
        #
        "lab" = hm.dag.entryBefore [ labNoVpn ] {
          host = concatStringsSep " " labMachines;
          hostname = "%h.${engDomain}";
          user = "eliza";
        };

        # if the Oxide VPN connection is *not* active, add a `proxyJump` to
        # connect to the VPN first. Don't do this if already on the VPN,
        # because it makes the SSH connection take longer to establish.
        ${labNoVpn} = {
          match = ''host "!vpn.${engDomain},*.${engDomain}" !exec "nmcli con show --active | grep 'oxide.*vpn'"'';
          proxyJump = "vpn.${engDomain}";
        };

        #
        # racklette gimlets by cubby number
        #
        ${racklette-gimlets} = hm.dag.entryBefore [ "lab" all-racklettes ] {
          host = trivial.pipe rackletteNames [
            (map (name: "${name}gc*"))
            (concatStringsSep " ")
          ];
          proxyCommand = ''ssh ${jeeves} pilot -r $(echo "%h" | sed 's/gc.*//') tp nc any $(echo "%h" | sed 's/.*gc//') %p'';
          forwardAgent = true;
          extraOptions = {
            ServerAliveInterval = "15";
          };
        };

        #
        # config applied to all of the above:
        #
        ${all-racklettes} = hm.dag.entryBefore [ jeeves ] {
          host = trivial.pipe rackletteNames [
            (map (name: "${name}*"))
            (concatStringsSep " ")
          ];
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
      #
      # individual racklettes
      #
      // (attrsets.mergeAttrsList (map mkRacklette racklettes));
  };
}
