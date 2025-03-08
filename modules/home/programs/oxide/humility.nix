{ pkgs, lib }:

with pkgs;
let
  pname = "humility";
  rev = "4e9b9f9efb455d62b44345b7c8659dcd962c73da";
  src = fetchFromGitHub
    {
      owner = "oxidecomputer";
      repo = pname;
      inherit rev;
      hash = "sha256-BzLduU2Wu4UhmgDvvuCEXsABO/jPC7AjptDW8/zePEk=";
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
      "hidapi-1.4.1" = "sha256-5ioUq/2EvJzIoFYUOD27c9gjwdGUpYaehZSCnTvYKFE=";
      "hif-0.3.1" = "sha256-o3r1akaSARfqIzuP86SJc6/s0b2PIkaZENjYO3DPAUo=";
      "humpty-0.1.3" = "sha256-efeb+RaAjQs9XU3KkfVo8mVK2dGyv+2xFKSVKS0vyTc=";
      "idol-0.3.0" = "sha256-s6ZM/EyBE1eOySPah5GtT0/l7RIQKkeUPybMmqUpmt8=";
      "idt8a3xxxx-0.1.0" = "sha256-S36fS9hYTIn57Tt9msRiM7OFfujJEf8ED+9R9p0zgK4=";
      "ipcc-data-0.0.1" = "sha256-x6E08l28GNPvL2K9+yYWMM/KHWFrNOnN58pVSvcsNFk=";
      "libusb1-sys-0.5.0" = "sha256-7Bb1lpZvCb+OrKGYiD6NV+lMJuxFbukkRXsufaro5OQ=";
      "pmbus-0.1.4" = "sha256-Sw/GYrBQSt3I49qZg4kK3q3kSYXd1qpWzlCt7ks9x/0=";
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
