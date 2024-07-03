{ pkgs, ... }:
{

  #### nix configurations ####

  nixpkgs.config.allowUnfree = true;

  nix = {
    # enable flakes
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    generateNixPathFromInputs = true;
    generateRegistryFromInputs = true;
    linkInputs = true;

    # It's good to do this every now and then.
    gc = {
      automatic = true;
      dates = "monthly"; # See `man systemd.time 7`
    };

    settings =
      let
        substituters = [
          "https://nix-community.cachix.org"
          "https://cache.garnix.io"
        ];
      in
      {
        trusted-users = [ "root" "eliza" ];
        extra-substituters = substituters;
        trusted-substituters = substituters;
        extra-trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        ];
      };
  };

}
