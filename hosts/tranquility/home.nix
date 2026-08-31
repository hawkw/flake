{ lib, ... }: {
  profiles = {
    opstools = {
      enable = true;
      net.enable = true;
    };
  };

  # TODO(eliza): figure out which editor to use more smartly...
  home.sessionVariables.EDITOR = lib.mkForce "nano"; # headless...
}
