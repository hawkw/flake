{ ... }:

{
  system.stateVersion = "23.11";
  raspberry-pi.hardware = {
    platform.type = "rpi3";
  };

  profiles.eclss-node.enable = true;
  services.eclssd.location = "office";
}
