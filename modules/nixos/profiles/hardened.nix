# various non-default security hardening configs.
# these are particularly important for servers exposed to the public internet.
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.profiles.hardened;
in
{
  options.profiles.hardened = {
    enable = mkEnableOption "security hardening configs";
    kernel = {
      enable = mkEnableOption "kernel hardening" // { default = true; };

      lockdownLevel = mkOption {
        type = types.enum [ "integrity" "confidentiality" ];
        default = "integrity";
      };

      requireSignedModules = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Require signed kernel modules.

          Enabling this may make VirtualBox or Nvidia drivers unusable, so it
          may be disabled.
        '';
      };

      disableDebugfs = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Disable debugfs.

          This prevents userspace from learning about the kernel, which can
          reduce attack surface, but you may also want to use debugfs, so...
        '';
      };
    };
    systemd = {
      enable = mkEnableOption "systemd hardening" // { default = true; };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = with pkgs; [ kernel-hardening-checker lynis ];

      # OpenSSH server hardening. This is based loosely on the configs suggested
      # at https://infosec.mozilla.org/guidelines/openssh#modern-openssh-67,
      # though we do not use their suggested key-exchange algorithms, as the
      # current NixOS defaults for OpenSSH 9.0+ will offer stronger kex
      # algorithms than Mozilla suggested here.
      services.openssh = {
        settings = {
          # LogLevel VERBOSE logs user's key fingerprint on login. Needed to have
          # a clear audit track of which key was used to log in.
          #
          # This is also required for NixOS' default fail2ban jail for sshd to
          # work properly.
          LogLevel = "VERBOSE";
          # Root login is not allowed for auditing reasons. This is because it's
          # difficult to track which process belongs to which root user:
          #
          # On Linux, user sessions are tracking using a kernel-side session id,
          # however, this session id is not recorded by OpenSSH. Additionally,
          # only tools such as systemd and auditd record the process session id.
          # On other OSes, the user session id is not necessarily recorded at all
          # kernel-side. Using regular users in combination with /bin/su or
          # /usr/bin/sudo ensure a clear audit track.
          PermitRootLogin = "no";

          PasswordAuthentication = false;
          KbdInteractiveAuthentication = true;
          KexAlgorithms = [
            # Post-Quantum: https://www.openssh.org/pq.html
            "mlkem768x25519-sha256"
            "sntrup761x25519-sha512"
            "curve25519-sha256@libssh.org"
            "ecdh-sha2-nistp521"
            "ecdh-sha2-nistp384"
            "ecdh-sha2-nistp256"
            "diffie-hellman-group-exchange-sha256"
          ];
          Ciphers = [
            "aes256-gcm@openssh.com"
            "aes128-gcm@openssh.com"
            # stream cipher alternative to aes256, proven to be resilient
            # Very fast on basically anything
            "chacha20-poly1305@openssh.com"
            # industry standard, fast if you have AES-NI hardware
            "aes256-ctr"
            "aes192-ctr"
            "aes128-ctr"
          ];
          Macs = [
            # Combines the SHA-512 hash func with a secret key to create a MAC
            "hmac-sha2-512-etm@openssh.com"
            "hmac-sha2-256-etm@openssh.com"
            "umac-128-etm@openssh.com"
            "hmac-sha2-512"
            "hmac-sha2-256"
            "umac-128@openssh.com"
          ];
        };
      };

      # TODO: firewall rules for sshd to only allow 10./8 addrs...

      # Enable fail2ban to ban IPs after too many failed login attempts.
      services.fail2ban = {
        enable = true;
        maxretry = 10;
        bantime-increment.enable = true;
        # TODO(eliza): probably should also setup fail2ban for other services
        # eventually...
      };
    }
    (mkIf cfg.kernel.enable {
      # Kernel hardening settings.
      security = {
        protectKernelImage = true;
        lockKernelModules = false; # setting this to true would break iptables, wireguard, and virtd

        # force-enable the Page Table Isolation (PTI) Linux kernel feature
        forcePageTableIsolation = true;

        # User namespaces are required for sandboxing.
        # this means you cannot set `"user.max_user_namespaces" = 0;` in sysctl
        allowUserNamespaces = true;

        # Disable unprivileged user namespaces, unless containers are enabled
        unprivilegedUsernsClone = config.virtualisation.containers.enable;
        allowSimultaneousMultithreading = true;
      };

      boot.kernelParams =
        let
          sigEnforce = if cfg.kernel.requireSignedModules then "1" else "0";
          debugfs = if cfg.kernel.disableDebugfs then "off" else "on";
        in
        [
          # make it harder to influence slab cache layout
          "slab_nomerge"
          # enables zeroing of memory during allocation and free time
          # helps mitigate use-after-free vulnerabilaties
          "init_on_alloc=1"
          "init_on_free=1"
          # randomizes page allocator freelist, improving security by
          # making page allocations less predictable
          "page_alloc.shuffel=1"
          # enables Kernel Page Table Isolation, which mitigates Meltdown and
          # prevents some KASLR bypasses
          "pti=on"
          # randomizes the kernel stack offset on each syscall
          # making attacks that rely on a deterministic stack layout difficult
          "randomize_kstack_offset=on"
          # disables vsyscalls, they've been replaced with vDSO
          "vsyscall=none"
          # disables debugfs, which exposes sensitive info about the kernel
          "debugfs=${debugfs}"
          # certain exploits cause an "oops", this makes the kernel panic if an
          # "oops" occurs
          "oops=panic"
          # only alows kernel modules that have been signed with a valid key to be
          # loaded making it harder to load malicious kernel modules
          #
          # this can make VirtualBox or Nvidia drivers unusable
          "module.sig_enforce=${sigEnforce}"
          # prevents user space from modifying kernel memory
          "lockdown=${builtins.toString cfg.kernel.lockdownLevel}"
          # "rd.udev.log_level=3"
          # "udev.log_priority=3"
        ];

      # See: https://kspp.github.io/Recommended_Settings#sysctls
      boot.kernel.sysctl = {
        "fs.suid_dumpable" = 0;
        # prevent pointer leaks
        "kernel.kptr_restrict" = 2;
        # restrict kernel log to CAP_SYSLOG capability
        "kernel.dmesg_restrict" = 1;
        # Note: certian container runtimes or browser sandboxes might rely on
        # the following restrict eBPF to the CAP_BPF capability
        "kernel.unprivileged_bpf_disabled" = 1;
        # should be enabled along with bpf above
        "net.core.bpf_jit_harden" = 2;
        # restrict loading TTY line disciplines to the CAP_SYS_MODULE
        "dev.tty.ldisk_autoload" = 0;
        # prevent exploit of use-after-free flaws
        "vm.unprivileged_userfaultfd" = 0;
        # kexec is used to boot another kernel during runtime and can be abused
        "kernel.kexec_load_disabled" = 1;
        # Kernel self-protection
        #
        # SysRq exposes a lot of potentially dangerous debugging functionality
        # to unprivileged users 4 makes it so a user can only use the secure
        # attention key. A value of 0 would disable completely
        "kernel.sysrq" = 4;
        # restrict all usage of performance events to the CAP_PERFMON capability
        "kernel.perf_event_paranoid" = 3;

        # Network
        # protect against SYN flood attacks (denial of service attack)
        "net.ipv4.tcp_syncookies" = 1;
        # protection against TIME-WAIT assassination
        "net.ipv4.tcp_rfc1337" = 1;
        # enable source validation of packets received (prevents IP spoofing)
        "net.ipv4.conf.default.rp_filter" = 1;
        "net.ipv4.conf.all.rp_filter" = 1;

        "net.ipv4.conf.all.accept_redirects" = 0;
        "net.ipv4.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.secure_redirects" = 0;
        "net.ipv4.conf.default.secure_redirects" = 0;
        # Protect against IP spoofing
        "net.ipv6.conf.all.accept_redirects" = 0;
        "net.ipv6.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;

        # prevent man-in-the-middle attacks
        "net.ipv4.icmp_echo_ignore_all" = 1;

        # ignore ICMP request, helps avoid Smurf attacks
        "net.ipv4.conf.all.forwarding" = 0;
        "net.ipv4.conf.default.accept_source_route" = 0;
        "net.ipv4.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.default.accept_source_route" = 0;
        # Reverse path filtering causes the kernel to do source validation of
        "net.ipv6.conf.all.forwarding" = 0;
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.default.accept_ra" = 0;

        ## TCP hardening
        # Prevent bogus ICMP errors from filling up logs.
        "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

        # Userspace
        # restrict usage of ptrace
        "kernel.yama.ptrace_scope" = 2;

        # ASLR memory protection (64-bit systems)
        "vm.mmap_rnd_bits" = 32;
        "vm.mmap_rnd_compat_bits" = 16;

        # only permit symlinks to be followed when outside of a world-writable sticky directory
        "fs.protected_symlinks" = 1;
        "fs.protected_hardlinks" = 1;
        # Prevent creating files in potentially attacker-controlled environments
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;

        # Randomize memory
        "kernel.randomize_va_space" = 2;
        # Exec Shield (Stack protection)
        "kernel.exec-shield" = 1;

        ## TCP optimization
        # TCP Fast Open is a TCP extension that reduces network latency by packing
        # data in the sender’s initial TCP SYN. Setting 3 = enable TCP Fast Open for
        # both incoming and outgoing connections:
        "net.ipv4.tcp_fastopen" = 3;
        # Bufferbloat mitigations + slight improvement in throughput & latency
        "net.ipv4.tcp_congestion_control" = "bbr";
        "net.core.default_qdisc" = "cake";
      };
    })
    (mkIf cfg.systemd.enable {
      services.dbus.implementation = "broker";

      systemd.services.systemd-journald = {
        serviceConfig = {
          UMask = 0077;
          PrivateNetwork = true;
          ProtectHostname = true;
          ProtectKernelModules = true;
        };
      };

      # TODO: want the various systemd service configs from
      # https://github.com/wallago/nix-system-services-hardened
    })
  ]);
}
