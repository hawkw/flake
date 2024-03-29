{ config, lib, pkgs, ... }:
let
  cfg = config.profiles.oxide;
in
with lib; {
  options.profiles.oxide = {
    enable = mkEnableOption "Profile with various Oxide stuff";
    looker = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable Looker, a Bunyan log viewer";
      };
    };
    humility = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable Humility, the Hubris debugger.";
      };
    };
  };

  config =
    mkIf cfg.enable (mkMerge [
      # scripts and env vars
      {
        home.packages = with pkgs;
          let
            atrium-sync = writeShellApplication
              {
                name = "atrium-sync";
                runtimeInputs = [ rsync ];
                text = builtins.readFile ./atrium-sync.sh;
              };
            atrium-run = writeShellApplication
              {
                name = "atrium";
                runtimeInputs = [ openssh rsync atrium-sync ];
                text = builtins.readFile ./atrium-run.sh;
              };
          in
          [ atrium-sync atrium-run ];
        programs.zsh.initExtra = ''
          export OMICRON_USE_FLAKE=1;
        '';
        home.sessionVariables = {
          # Tell direnv to opt in to using the Nix flake for Omicron.
          OMICRON_USE_FLAKE = " 1 ";
        };
      }
      # looker package
      (mkIf cfg.looker.enable (
        let
          looker = with pkgs;
            let
              pname = "looker";
              rev = "173a93c92ac78068569b252d3ec8a1cef4be1de6";
              src = fetchFromGitHub
                {
                  owner = "oxidecomputer";
                  repo = pname;
                  inherit rev;
                  hash = "sha256-V5hnr3e+GyxejcQSoqo+R/2tAXM3mfUtXR2ezKKVV7Q=";
                };
            in
            rustPlatform.buildRustPackage
              {
                inherit src pname;
                version = rev;
                cargoLock = {
                  lockFile = "${src}/Cargo.lock";
                };
              };
        in
        { home.packages = [ looker ]; }
      ))
      # humility package
      (mkIf cfg.humility.enable
        (
          let
            humility = with pkgs;
              let
                pname = "humility";
                rev = "d0a6e0317ba502a44e1e0bc4372e065dd6ecd2fe";
                src = fetchFromGitHub
                  {
                    owner = "oxidecomputer";
                    repo = pname;
                    inherit rev;
                    hash = "sha256-YGfMqhIv2JQDOBpHWitGqAtgxg8dMlY893RZ7fnU0Ws=";
                  };
              in
              rustPlatform.buildRustPackage {
                inherit src pname;
                version = rev;
                cargoLock = {
                  lockFile = "${src}/Cargo.lock";
                  # handle git deps. see see Artemis' blog post at
                  # https://artemis.sh/2023/07/08/nix-rust-project-with-git-dependencies.html
                  outputHashes = {
                    "capstone-0.10.0" = "sha256-x0p005W6u3QsTKRupj9HEg+dZB3xCXlKb9VCKv+LJ0U=";
                    "gimlet-inspector-protocol-0.1.0" = "sha256-NLKiYL1CMkQaaTP0ePwEK49Y9lckkOrzw7371SHHEWQ=";
                    "hidapi-1.4.1" = "sha256-2SBQu94ArGGwPU3wJYV0vwwVOXMCCq+jbeBHfKuE+pA=";
                    "hif-0.3.1" = "sha256-o3r1akaSARfqIzuP86SJc6/s0b2PIkaZENjYO3DPAUo=";
                    "humpty-0.1.3" = "sha256-efeb+RaAjQs9XU3KkfVo8mVK2dGyv+2xFKSVKS0vyTc=";
                    "idol-0.3.0" = "sha256-s6ZM/EyBE1eOySPah5GtT0/l7RIQKkeUPybMmqUpmt8=";
                    "idt8a3xxxx-0.1.0" = "sha256-S36fS9hYTIn57Tt9msRiM7OFfujJEf8ED+9R9p0zgK4=";
                    "libusb1-sys-0.5.0" = "sha256-7Bb1lpZvCb+OrKGYiD6NV+lMJuxFbukkRXsufaro5OQ=";
                    "pmbus-0.1.2" = "sha256-NFSrh4yD7PCqYhGuioRYWFmFIcpFvDO1qh6Lp9tsJ9E=";
                    "probe-rs-0.12.0" = "sha256-/L+85K6uxzUmz/TlLLFbMlyekoXC/ClO33EQ/yYjQKU=";
                    "spd-0.1.0" = "sha256-X6XUx+huQp77XF5EZDYYqRqaHsdDSbDMK8qcuSGob3E=";
                    "tlvc-0.2.0" = "sha256-HiqDRqmKOTxz6UQSXNMOZdWdc5W+cFGuKBkNrqFvIIE=";
                    "vsc7448-info-0.1.0" = "sha256-otNLdfGIzuyu03wEb7tzhZVVMdS0of2sU/AKSNSsoho=";
                  };
                };

                nativeBuildInputs = [ pkg-config ];
                buildInputs = [ udev ];

                PKG_CONFIG_PATH = "${pkgs.udev.dev}/lib/pkgconfig";
              };
          in
          {
            home.packages = [ humility ];
          }
        ))
    ]);
}
