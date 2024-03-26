# eliza's big nix flake

## layout

- [`hosts/`](./hosts) --- per-machine configuration
    + [`hosts/noctis/`](./hosts/noctis) --- **noctis**: desktop workstation (AMD Ryzen 3900X)
    + [`hosts/theseus/](./hosts/theseus)  --- **theseus**: Framework 13 (AMD Ryzen 7840U)
- [`lib/`](./lib)  --- reusable nix utilities
- [`modules/`](./modules) --- modules used by system configurations
    + [`modules/home/`](./modules/home) --- home-manager modules
        * [`modules/home/profiles/`](./modules/home/profiles) --- home-manager
          profiles (containing my personal preferences)
    + [`modules/nixos/`](./modules/nixos) --- NixOS modules
        * [`modules/nixos/profiles/`](./modules/nixos/profiles) --- NixOS
          profiles (containing my personal preferences)
        * [`modules/nixos/programs/`](./modules/nixos/programs) --- NixOS modules
          for configuring specific programs (generic and unopinionated )
- [`pkgs/](./pkgs) --- overlay with packages for stuff not currently in nixpkgs
```
