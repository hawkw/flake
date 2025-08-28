# hekate

## initial `disko` setup
```console
sudo nix \
  --extra-experimental-features 'nix-command flakes' \
  run 'github:nix-community/disko/latest#disko-install' -- \
  --write-efi-boot-entries \
  --flake '.#hekate' \
  --disk boot /dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S3PZNF0JA28518H \ --disk sn840-A079DDAA /dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079DDAA \
  --disk sn840-A079E3F9 /dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079E3F9 \
  --disk sn840-A079E4D6 /dev/disk/by-id/nvme-WUS4C6432DSP3X3_A079E4D6 \
  --disk sn840-A084A645 /dev/disk/by-id/nvme-WUS4C6432DSP3X3_A084A645
```
