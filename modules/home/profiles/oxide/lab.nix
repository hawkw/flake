{ config, lib, ... }:

let
  cfg = config.profiles.oxide;
in
with lib; {
  config = mkIf cfg.enable {
    programs.ssh.matchBlocks =
      let
        switchZoneHostname = "fe80::aa40:25ff:fe05:602%%madrid_sw1tp0";
        vpn = "vpn.eng.oxide.computer";
        madrid = "madrid";
        madrid-all = "${madrid}-all";
        madridgc = "${madrid}gc";
        jeeves = "jeeves";
        mkLabMachine = name: {
          host = name;
          hostname = "${name}.eng.oxide.computer";
          proxyJump = "${vpn}";
          user = "eliza";
        };
      in
      {
        ###
        ### lab machines
        ###
        ${jeeves} = hm.dag.entryAfter [ madridgc ] (mkLabMachine jeeves);
        atrium = mkLabMachine "atrium";
        cadbury = mkLabMachine "cadbury";
        yuban = mkLabMachine "yuban";
        lurch = mkLabMachine "lurch";

        ###
        ### madrid
        ###

        #
        # root in the global zone of the scrimlet:
        #
        "${madrid}gz" = hm.dag.entryBefore [ madrid-all ] {
          host = "${madrid}gz";
          hostname = "fe80::eaea:6aff:fe09:7f66%%${madrid}_host0";
        };

        #
        # Wicket in the switch zone:
        #
        "${madrid}wicket" = hm.dag.entryBefore [ madrid-all ] {
          host = "${madrid}wicket";
          hostname = switchZoneHostname;
          user = "wicket";
        };

        #
        # root in the switch zone:
        #
        "${madrid}switch" = hm.dag.entryBefore [ madrid-all ] {
          host = "${madrid}switch";
          hostname = switchZoneHostname;
        };

        #
        # madrid gimlets by cubby number
        #
        ${madridgc} = hm.dag.entryBefore [ "${madrid}-all" ] {
          host = "${madridgc}*";
          proxyCommand = ''ssh ${jeeves} pilot -r ${madrid} tp nc any $(echo "%h" | sed s/${madridgc}//) %p'';
          forwardAgent = true;
          proxyJump = vpn;
          extraOptions = {
            ServerAliveInterval = "15";
          };
        };

        #
        # config applied to all of the above:
        #
        "${madrid}-all" = hm.dag.entryBefore [ jeeves ] {
          host = "${madrid}*";
          user = "root";
          proxyJump = jeeves;
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
