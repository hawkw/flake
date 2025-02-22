{ ... }: {
  profiles = {
    desktop = {
      opstools = {
        enable = true;
        net.enable = true;
        supermicro.enable = true;
      };
    };
  };
}
