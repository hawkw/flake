let
  inherit (builtins) readDir hasAttr attrNames filter concatMap listToAttrs;

  loadHosts = dir: inputs:
    let
      loadConf = dir: n: (import "${dir}/${n}" inputs) // { hostname = n; };

      hosts' =
        let contents = readDir dir;
        in filter (n: contents."${n}" == "directory") (attrNames contents);
    in
    concatMap
      (n:
        let
          contents = readDir "${dir}/${n}";
          hasDefault = (hasAttr "default.nix" contents)
            && (contents."default.nix" == "regular");
        in
        if hasDefault then [ (loadConf dir n) ] else [ ])
      hosts';
in
{
  # Discover NixOS configurations.
  # It will find all sub-directories in `directory` and
  # include it if it has a default.nix.
  genNixOSHosts =
    { inputs
    , self
    , directory ? "${inputs.self}/hosts"
    , nixpkgs ? inputs.nixpkgs
    , builder ? nixpkgs.lib.nixosSystem
    , specialArgs ? { }
    , baseModules ? [ ]
    , homeManager ? null
    , overlays ? [ ]
    , config ? { allowUnfree = true; }
    }:
    let
      mkHost = conf@{ system, modules, hostname, ... }:
        let
          homeManagerModule =
            if homeManager != null && hasAttr "home" conf then
              [
                ({ ... }: {
                  home-manager = {
                    # set `useUserPackages` to move `home.packages` into the
                    # system closure (as `/etc/profiles/per-user/<user>`), so
                    # that home-manager packages switch and roll back atomically
                    # with the system config.
                    #
                    # this also moves `home.profileDirectory` into
                    # `/etc/profiles/per-user`, there, so a standalone
                    # `home-manager switch` would build a *different* generation
                    # (in `~/.local/state/nix/profile`) while sharing the
                    # same activation state, and each would undo the other's
                    # package installation. this is why we *only* build the HM
                    # config as part of the system config, and avoid standalone
                    # `homeConfigurations`.
                    useUserPackages = true;
                    extraSpecialArgs = { inherit inputs self; };
                    users.${homeManager.user} = {
                      nixpkgs = { inherit overlays config; };
                      imports = homeManager.baseModules ++ conf.home.modules;
                    };
                  };
                })
              ]
            else
              [ ];
        in
        builder {
          inherit system;

          specialArgs = { inherit inputs self; } // specialArgs;

          modules = [
            ({ ... }: {
              networking.hostName = hostname;

              nixpkgs = { inherit overlays config; };
            })
          ] ++ baseModules ++ modules ++ homeManagerModule;
        };
    in
    listToAttrs (map
      (conf: {
        name = conf.hostname;
        value = mkHost conf;
      })
      (loadHosts directory inputs));
}
