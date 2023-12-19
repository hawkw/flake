{ config, pkgs, lib, ... }:
let
  githubName = "prometheus-mdns-sd";
  githubOwner = "suprememoocow";
in pkgs.buildGoModule rec {
  pname = githubName;
  version = "0.0.1";

  src = pkgs.fetchFromGitHub {
    owner = githubOwner;
    repo = githubName;
    rev = "084a7c759b7f1173aff711f04aab368c89bd2f56";
    sha256 = "sha256-0da4LrH3FQWS/OYklzsdNLlSnWn3GbdZVKFurEVUUlU=";
  };

  vendorHash = "sha256-FdoFYsss7RGBlueySlFKKXvwax3oVUhc21QSJHfR3eE=";
}
