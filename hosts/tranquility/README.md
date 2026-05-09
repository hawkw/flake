## initial disko setup

```console
sudo nix \
  --extra-experimental-features 'nix-command flakes' \
  run 'github:nix-community/disko/latest#disko-install' -- \
  --write-efi-boot-entries \
  --flake '.#tranquility' \
  --disk nvme0n1 /dev/disk/by-id/nvme-CT1000P510SSD5_2525E9C382B2
```
