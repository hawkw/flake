{ ... }: {

  raspberry-pi.hardware = {
    platform.type = "rpi3";
  };

  system.stateVersion = "23.11";
  profiles.eclss-node.enable = true;
  services.eclssd.location = "kitchen";
}
