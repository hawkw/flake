{ pkgs, ... }:

{
  profiles = {
    desktop = {
      enable = true;
      gnome3.enable = true;
    };
    devtools = {
      enable = true;
      enablePython = true;
    };
    oxide = {
      enable = true;
      humility = {
        enable = true;
        environment =
          let
            basePath = "/home/eliza/Code/oxide/hubris/target";
          in
          {
            "gimletlet" = {
              probe = "0483:3754:000B00154D46501520383832";
              archive = "${basePath}/gimletlet/dist/default/build-gimletlet-image-default.zip";
            };
            "nucleo" = {
              probe = "0483:374e:0030003C3431511237393330";
              archive = "${basePath}/demo-stm32h753-nucleo/dist/default/build-demo-stm32h753-nucleo-image-default.zip";
            };
            "rot" = {
              probe = "1fc9:0143:53BKD0YYVRBPB";
              archive = {
                "a" = "${basePath}/rot-carrier/dist/a/build-rot-carrier-image-a.zip";
                "b" = "${basePath}/rot-carrier/dist/b/build-rot-carrier-image-b.zip";
              };
            };
          };
      };
    };
  };

  home.packages = with pkgs; [
    # not trying to build ESP32-C3 on this machine, so global clang is fine...
    clang
    # global pkgconfig too
    pkg-config
    qemu
    screen
  ];
}
