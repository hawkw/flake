{ ... }:

{
  system.stateVersion = "23.11";
  raspberry-pi.hardware = {
    platform.type = "rpi3";
  };

  hardware.raspberry-pi."4".apply-overlays-dtmerge.enable = true;
  profiles.eclss-node.enable = true;
  profiles.raspberry-pi.poe-hat.enable = true;
  services.eclssd = {
    location = "office";
    readoutd.ssd1680.enable = true;
  };
}
