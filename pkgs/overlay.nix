final: prev: {
  ckan-1_29 = prev.callPackage ./ckan-1_29.nix { };
  prometheusMdns = prev.callPackage ./prometheus-mdns.nix { };
  technic-launcher = prev.callPackage ./technic-launcher.nix { };
  xfel = prev.callPackage ./xfel.nix { };
}
