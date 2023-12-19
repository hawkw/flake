{ pkgs ? import <nixos-unstable> { } }:
let logiopsVersion = "0.2.3";
in with pkgs;
stdenv.mkDerivation {
  pname = "logiops";
  version = logiopsVersion;

  rev = "0a26579d5a586a92f288ffe4e77c896bb091c767";

  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ libevdev libudev libconfig ];

  src = fetchFromGitHub {
    owner = "PixlOne";
    repo = "logiops";
    rev = "v${logiopsVersion}";
    sha256 = "1wgv6m1kkxl0hppy8vmcj1237mr26ckfkaqznj1n6cy82vrgdznn";
  };

  configurePhase = ''
    cmake .
  '';

  buildPhase = ''
    make
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp logid $out/bin/logid
    cp logid.example.cfg $out/logid.example.cfg
    cp logid.service $out/logid.service
  '';

  meta = with pkgs.lib; {
    description =
      "logiops, an unofficial driver for Logitech mice and keyboards";
    homepage = "https://github.com/PixlOne/logiops";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
  };
}
