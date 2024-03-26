# eliza's big nix flake

## layout

- [`hosts/`](./hosts) &mdash; per-machine configuration
    + [`hosts/noctis/`](./hosts/noctis) &mdash; **noctis**: desktop workstation (AMD Ryzen 3900X)
    + [`hosts/theseus/`](./hosts/theseus) &mdash; **theseus**: Framework 13 (AMD Ryzen 7840U)
- [`lib/`](./lib)  &mdash; reusable nix utilities
- [`modules/`](./modules) &mdash; modules used by system configurations
    + [`modules/home/`](./modules/home) &mdash; home-manager modules
        * [`modules/home/profiles/`](./modules/home/profiles) &mdash; home-manager
          profiles (containing my personal preferences)
    + [`modules/nixos/`](./modules/nixos) &mdash; NixOS modules
        * [`modules/nixos/profiles/`](./modules/nixos/profiles) &mdash; NixOS
          profiles (containing my personal preferences)
        * [`modules/nixos/programs/`](./modules/nixos/programs) &mdash; NixOS modules
          for configuring specific programs (generic and unopinionated )
- [`pkgs/`](./pkgs) &mdash; overlay with packages for stuff not currently in nixpkgs
```
