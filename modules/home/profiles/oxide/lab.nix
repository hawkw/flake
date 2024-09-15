{ config, lib, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {
  config = mkIf cfg.enable {
    programs.ssh.matchBlocks =
      let
        jeeves = "jeeves";
        engDomain = "eng.oxide.computer";
        all-racklettes = "all-racklettes";
        racklette-gimlets = "racklette-gimlets";
        mkRacklette =
          {
            # name of the racklet
            name
          , # list of scrimlet serials
            scrimletSerials
          ,
          }: (
            let
              brm = "${name}BRM";
              scrimletGzs =
                let
                  mkGz =
                    (n: serial:
                      let h = "${name}gz${toString n}"; in {
                        ${h} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                          host = h + (if n == 0 then " ${name}gz" else "");
                          user = "root";
                          extraOptions = {
                            ProxyCommand = "ssh ${jeeves} pilot -r ${name} host nc ${serial} %p";
                          };
                        };
                      });
                in
                attrsets.mergeAttrsList (imap0 mkGz scrimletSerials);
              switches =
                let
                  mkSwitch = (n:
                    let
                      h = "${name}switch${toString n}";
                      extraOptions = {
                        ProxyCommand = "ssh ${jeeves} pilot -r ${name} tp nc ${toString n} %p";
                      };
                    in
                    {
                      ${h} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                        host = h + (if n == 1 then " ${name}switch" else "");
                        user = "root";
                        inherit extraOptions;
                      };
                    } // (if n == 1 then {
                      "${name}wicket" = hm.dag.entryBefore [ all-racklettes racklette-gimlets ] {
                        host = "${name}wicket";
                        user = "wicket";
                        inherit extraOptions;
                      };
                    } else { }));
                in
                attrsets.mergeAttrsList (map mkSwitch [ 0 1 ]);
            in
            {
              ${brm} = hm.dag.entryBefore [ all-racklettes racklette-gimlets ]
                {
                  host = "${brm}*";
                  extraOptions = {
                    ProxyCommand = ''ssh ${jeeves} pilot -r ${name} tp nc any $(echo %h | sed 's/^${name}//' | tr "[:lower:]" "[:upper:]") %p'';
                  };
                };
            } // scrimletGzs // switches
          );
        labMachines = [ jeeves "atrium" "cadbury" "yuban" "lurch" "alfred" ];
        racklettes = [
          # racklette: madrid
          {
            name = "madrid";
            # note madrid only has one k.2-accessible scrimlet, while london has
            # two.
            scrimletSerials = [ "BRM42220007" ];
          }
          # racklette: london
          {
            name = "london";
            scrimletSerials = [ "BRM42220036" "BRM42220030" ];
          }
        ];
        rackletteNames = attrsets.catAttrs "name" racklettes;
        labBlock = "lab";
        labNoVpnBlock = "lab-no-vpn";
      in
      {
        #
        # oxide lab machines
        #
        ${labBlock} = hm.dag.entryBefore [ labNoVpnBlock ] {
          host = concatStringsSep " " labMachines;
          hostname = "%h.${engDomain}";
          user = "eliza";
        };

        # if the Oxide VPN connection is *not* active, add a `proxyJump` to
        # connect to the VPN first. Don't do this if already on the VPN,
        # because it makes the SSH connection take longer to establish.
        ${labNoVpnBlock} = {
          match = ''host "!vpn.${engDomain},*.${engDomain}" !exec "nmcli con show --active | grep 'oxide.*vpn'"'';
          proxyJump = "vpn.${engDomain}";
        };

        #
        # racklette gimlets by cubby number
        #
        ${racklette-gimlets} = hm.dag.entryBefore [ labBlock all-racklettes ] {
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
        ${all-racklettes} = hm.dag.entryBefore [ labBlock ] {
          host = trivial.pipe rackletteNames [
            (map (name: "${name}*"))
            (concatStringsSep " ")
          ];
          user = "root";
          proxyJump = "jeeves.eng.oxide.computer";
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
