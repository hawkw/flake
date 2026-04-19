{ ... }:

{
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBU+Py8pd6bqyPkiSYopmL/MapIM97vK4jKtrSz9nl8f";

  system.stateVersion = "23.11";
  raspberry-pi.hardware = {
    platform.type = "rpi3";
  };

  hardware.raspberry-pi."4".apply-overlays-dtmerge.enable = true;
  profiles = {
    eclss-node.enable = true;
    raspberry-pi.poe-hat.enable = true;
    server.enable = true;
  };
  services.eclssd = {
    location = "office";
    readoutd.ssd1680.enable = true;
  };
}
