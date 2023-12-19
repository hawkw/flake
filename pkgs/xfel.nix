{ stdenv, lib, fetchFromGitHub, libusb1, pkg-config, gcc, gnumake }:

stdenv.mkDerivation rec {
  pname = "xfel";
  version = "1.3.2";

  src = fetchFromGitHub {
    owner = "xboot";
    repo = "xfel";
    rev = "v${version}";
    sha256 = "sha256-fmf+jqCWC7RaLknr/TyRV6VQz4+fp83ynHNk2ACkyfQ=";
  };

  nativeBuildInputs = [ pkg-config gcc gnumake ];
  buildInputs = [ libusb1 ];

  makeFlags = [ "DESTDIR=$(out)" "PREFIX=''" ];

  meta = with lib; {
    description =
      "Tiny FEL tools for allwinner SOCs, including the RISC-V D1 chip ";
    license = licenses.mit;
    homepage = "https://xboot.org/xfel/";
    platforms = platforms.all;
  };
}
