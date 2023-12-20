{ stdenv, lib, fetchFromGitHub, makeWrapper, perl, mono, gtk2, curl }:

stdenv.mkDerivation rec {
  pname = "ckan";
  version = "1.29.2";

  src = fetchFromGitHub {
    owner = "KSP-CKAN";
    repo = "CKAN";
    rev = "v${version}";
    sha256 = "0lfvl8w09lakz35szp5grfvhq8xx486f5igvj1m6azsql4n929lg";
  };

  buildInputs = [ makeWrapper perl mono ];

  postPatch = ''
    substituteInPlace bin/build \
      --replace /usr/bin/perl ${perl}/bin/perl
  '';

  # Tests don't currently work, as they try to write into /var/empty.
  doCheck = false;
  checkTarget = "test";

  libraries = lib.makeLibraryPath [ gtk2 curl ];

  installPhase = ''
    mkdir -p $out/bin
    for exe in *.exe; do
      install -m 0644 $exe $out/bin
      makeWrapper ${mono}/bin/mono $out/bin/$(basename $exe .exe) \
        --add-flags $out/bin/$exe \
        --set LD_LIBRARY_PATH $libraries
    done
  '';

  meta = {
    description = "Mod manager for Kerbal Space Program";
    homepage = "https://github.com/KSP-CKAN/CKAN";
    license = lib.licenses.mit;
    maintainers = [ lib.maintainers.Baughn ];
    platforms = lib.platforms.all;
  };
}
