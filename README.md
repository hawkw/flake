# eliza's big nix flake

## layout

- [`hosts/`](./hosts) &mdash; per-machine configuration
    + [`hosts/clavius/`](./hosts/clavius) &mdash; **clavius**: Raspberry Pi 4 (ECLSS node)
    + [`hosts/hekate/`](./hosts/hekate) &mdash; **hekate**: engineering server (AMD, Supermicro X11/X12)
    + [`hosts/noctis/`](./hosts/noctis) &mdash; **noctis**: desktop workstation (AMD Ryzen 3900X)
    + [`hosts/tereshkova/`](./hosts/tereshkova) &mdash; **tereshkova**: infrastructure server
    + [`hosts/theseus/`](./hosts/theseus) &mdash; **theseus**: Framework 13 (AMD Ryzen 7840U)
    + [`hosts/tycho/`](./hosts/tycho) &mdash; **tycho**: Raspberry Pi 4 (ECLSS node)
- [`lib/`](./lib)  &mdash; reusable nix utilities
- [`modules/`](./modules) &mdash; modules used by system configurations
    + [`modules/home/`](./modules/home) &mdash; home-manager modules
        * [`modules/home/profiles/`](./modules/home/profiles) &mdash; home-manager
          profiles (containing my personal preferences)
    + [`modules/nixos/`](./modules/nixos) &mdash; NixOS modules
        * [`modules/nixos/hardware/`](./modules/nixos/hardware) &mdash; NixOS modules
          for hardware devices (generic and unopinionated)
        * [`modules/nixos/profiles/`](./modules/nixos/profiles) &mdash; NixOS
          profiles (containing my personal preferences)
        * [`modules/nixos/programs/`](./modules/nixos/programs) &mdash; NixOS modules
          for configuring specific programs (generic and unopinionated)
- [`pkgs/`](./pkgs) &mdash; overlay with packages for stuff not currently in nixpkgs
- [`secrets/`](./secrets) &mdash; encrypted secrets managed by
  [agenix-rekey]

## secrets

secrets are managed with [agenix-rekey], which extends [agenix] with automatic
rekeying from a master identity. the master identity is a 1Password SSH key
accessed via [age-plugin-1p], so the actual private key material never touches
disk.

### how it works

secrets stored in the repo are encrypted to the master identity only. when you
run `agenix rekey`, each secret is decrypted (via 1Password) and re-encrypted to
whichever host SSH public keys need it. the rekeyed per-host copies live under
`secrets/rekeyed/<hostname>/` and are what actually get deployed. at activation
time, the host decrypts its own copies using its SSH host key.

this means:
- adding or replacing a host is just `agenix rekey` &mdash; no per-secret
  recipient lists to maintain
- secrets in git history are only decryptable by the master identity, not by
  any individual host key
- 1Password biometric/password is the only authentication needed for secret
  management

### directory layout

```
secrets/
├── master-identities/
│   └── 1password-ssh.pub  # age-plugin-1p identity (references 1Password, safe to commit)
├── host-keys/
│   ├── hekate.pub         # ssh-ed25519 host public keys, one per host
│   ├── noctis.pub
│   └── ...
└── rekeyed/               # output of `agenix rekey` (per-host encrypted copies)
    ├── hekate/
    ├── noctis/
    └── ...
```

### prerequisites

you need the following on your local machine:

- the [1Password CLI](https://1password.com/downloads/command-line/) (`op`) on `$PATH`
- `age-plugin-1p` on `$PATH` (available in the flake's devshell)
- an age identity file generated from your 1Password SSH key (see below)

### generating the master identity

if the master identity doesn't exist yet:

```sh
age-plugin-1p \
  --generate "op://Personal/SSH key/private key" \
  -o secrets/master-identities/1password-ssh.pub
```

replace the `op://` URI with the secret reference to your ed25519 SSH key. the
resulting file contains a plugin reference, not key material, so it's safe to
commit.

### creating a new secret

```sh
# interactively create/edit via $EDITOR
agenix edit secrets/my-new-secret.age

# or encrypt an existing file
agenix edit -i /tmp/plaintext.bin secrets/my-new-secret.age
```

then reference it in your NixOS config:

```nix
age.secrets.my-new-secret.rekeyFile = ./secrets/my-new-secret.age;
services.whatever.passwordFile = config.age.secrets.my-new-secret.path;
```

### rekeying

after adding a host, changing a host key, or adding/modifying a secret:

```sh
agenix rekey -a
```

the `-a` flag automatically `git add`s the rekeyed output files.

### adding a new host

1. grab the host's ed25519 SSH public key:
   ```sh
   ssh-keyscan -t ed25519 newhost.example.com 2>/dev/null | awk '{print $2, $3}'
   ```
2. save it to `secrets/host-keys/newhost.pub`
3. set `age.rekey.hostPubkey` in the host's config (the shared secrets module
   does this automatically from `secrets/host-keys/${hostname}.pub`)
4. declare whichever `age.secrets.*` the host needs
5. run `agenix rekey -a`

[agenix]: https://github.com/ryantm/agenix
[agenix-rekey]: https://github.com/oddlama/agenix-rekey
[age-plugin-1p]: https://github.com/Enzime/age-plugin-1p
