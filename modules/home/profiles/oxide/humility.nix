{ pkgs }:

with pkgs;
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
  # use the Rust toolchain specified in the project's rust-toolchain.toml
  configuredRustPlatform =
    let
      file = src + "/rust-toolchain.toml";
      rustToolchain = rust-bin.fromRustupToolchainFile file;
    in
    makeRustPlatform {
      cargo = rustToolchain;
      rustc = rustToolchain;
    };

in
configuredRustPlatform.buildRustPackage {
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

  PKG_CONFIG_PATH = "${udev.dev}/lib/pkgconfig";
}
