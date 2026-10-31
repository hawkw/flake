# Configuration for Linux performance profiling tools (perf, ebpf tracing,
# flamegraphs).
{ config, lib, pkgs, ... }:

with lib;
let
  linuxpkgs = config.boot.kernelPackages;
  cfg = config.profiles.perftools.enable;
in
{
  options.profiles.perftools.enable = mkEnableOption "perftools";

  config = mkIf cfg {
    environment.systemPackages = with pkgs; [
      # use the correct version of `perf` for the configured `linuxPackages`
      perf
      # also include userspace perf-tools and flamegraph scripts
      perf-tools
      flamegraph
    ]
    # turbostat reads x86 MSRs, so only enable it on x86.
    ++ optional pkgs.stdenv.hostPlatform.isx86 linuxpkgs.turbostat;
    # turbostat reads RAPL energy counters and C-state residency through
    # `/dev/cpu/*/msr`, which requires the `msr` module.
    boot.kernelModules = optional pkgs.stdenv.hostPlatform.isx86 "msr";
    # this does the same thing as above (using the correct `linuxPackages`) but
    # for `bcc`...sad there's no version of this for perf out of the box.
    programs.bcc.enable = true;
  };
}
