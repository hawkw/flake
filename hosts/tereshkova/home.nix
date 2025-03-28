{ ... }: {
  profiles = {
    opstools = {
      enable = true;
      net.enable = true;
      supermicro.enable = true;
    };
    oxide = {
      enable = true;
    };
  };
}
