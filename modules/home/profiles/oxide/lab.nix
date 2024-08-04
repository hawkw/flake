{ config, lib, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {
  config = mkIf cfg.enable {
    programs.ssh.matchBlocks =
      let
        switchZoneHostname = "fe80::aa40:25ff:fe05:602%%madrid_sw1tp0";
        jeeves = "jeeves.eng.oxide.computer";
        madridgc = "madridgc";
      in
      {
        #
        # root in the global zone of the scrimlet:
        #
        madridgz = hm.dag.entryBefore [ "madrid-all" ] {
          host = "madridgz";
          hostname = "fe80::eaea:6aff:fe09:7f66%%madrid_host0";
        };

        #
        # Wicket in the switch zone:
        #
        madridwicket = hm.dag.entryBefore [ "madrid-all" ] {
          host = "madridwicket";
          hostname = switchZoneHostname;
          user = "wicket";
        };

        #
        # root in the switch zone:
        #
        madridswitch = hm.dag.entryBefore [ "madrid-all" ] {
          host = "madridswitch";
          hostname = switchZoneHostname;
        };

        #
        # madrid gimlets by cubby number
        #
        ${madridgc} = hm.dag.entryBefore [ "madrid-all" ] {
          host = "${madridgc}*";
          proxyCommand = ''ssh ${jeeves} pilot tp nc any $(echo "%h" | sed s/${madridgc}//) %p'';
          forwardAgent = true;
          extraOptions = {
            ServerAliveInterval = "15";
          };
        };

        #
        # config applied to all of the above:
        #
        madrid-all = {
          host = "madrid*";
          user = "root";
          proxyJump = "vpn.eng.oxide.computer,${jeeves}";
          extraOptions = {
            # Every time Madrid is reset, the host key changes, so silence all
            # of openssh's warnings that "SOMEONE MIGHT BE DOING SOMETHING
            # NASTY".
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
            LogLevel = "error";
          };
        };
      };
  };
}
