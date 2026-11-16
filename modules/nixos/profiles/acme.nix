# Wildcard TLS certificate for a host's reverse proxy and other services.
#
# This profile requests a single certificate for `domain` and `*.domain` from
# Let's Encrypt, using the DNS-01 challenge. Because the DNS-01 challenge only
# requires access to the DNS provider's API, no inbound port needs to be
# reachable by the public internet (unlike the HTTP-01 challenge). The provider
# and its credentials are configured by the `dnsProvider` and `credentialFiles`
# options.
#
# ## On Wildcards
#
# Using a wildcard certificate, rather than requesting a separate one for every
# subdomain, has two main consequences:
#
# - Adding a vhost or a service under `domain` does not change the certificate,
#   so it does not trigger a reissue.
# - Only `domain` and `*.domain` appear in Certificate Transparency logs. The
#   actual names of any subdomains using the wildcard are not published in the
#   public Certificate Transparency logs, which is nice to keep the domains of
#   private services a bit more...private.
#
# Note that a wildcard certificate is valid for exactly one DNS label. For
# example, if the wildcard is `*.domain`, then it is valid for `a.domain` and
# `b.domain`, but not for `x.a.domain`.
#
# To add additional subject alternate names (SANs) to the certificate, add them
# to the `extraDomainNames` option. Literal names there *are* published in the
# CT logs, but additional wildcards (i.e. a nested `*.b.domain`, or a wildcard
# under a sibling domain) will only publish the wildcard. See RFC 6125 6.4.3.
#
# The certificate requested by this module may be used by multiple dependent
# services.
#
# ### Reverse Proxies
#
# This module automatically supports the nginx and Caddy NixOS modules, and any
# vhost configured for those reverse proxies that selects the cert by setting
# `useACMEHost` to the value of `options.profiles.acme.domain` will be
# configured to use it automatically. This module asserts that every nginx or
# Caddy vhost that selects this cert (via `useACMEHost`) matches the wildcard
# rule. This ensures that a vhost that would fail the TLS name check fails
# evaluation instead.
#
# Only one of nginx or Caddy may be enabled on a host, since both bind 80/443.
# This module asserts that only one is enabled.
#
# ### Consuming Certificates
#
# The certificate file is owned by the `acme` user and group, and the
# key file is readable by the `acme` group. Therefore, a service that uses the
# cert needs to be able to:
#
# 1. read `${directory}/{fullchain,key}.pem`, either by running as root, or
#    by having its user listed in `users` (nginx and Caddy are added
#    automatically when they have a vhost using this cert),
# 2. be restarted/reloaded when the cert renews, by being listed in
#    `reloadServices` (the nginx and Caddy modules add themselves to this by
#    default), and,
# 3. start after `acme-${domain}.service`, which installs a self-signed
#    placeholder if no real cert exists yet, so that consumers can start
#    before first issuance completes.
#
# For example, in order to add a `zrepl` TLS transport, one would configure
# zrepl to set `cert`/`key` from `directory`, and add `zrepl.service` to
# `reloadServices`.
#
{ config, lib, ... }:

with lib;
let
  cfg = config.profiles.acme;
  cfgNginx = config.services.nginx;
  cfgCaddy = config.services.caddy;

  # The group that may read the cert's private key.
  group = "acme";

  # Build lists of virtual hostnames served by Caddy or nginx that use the cert
  # configured in this module, in the format:
  # `{ vhost = <attr name>; names = [ ... ]; }`.

  # Luckily, both the nginx and Caddy modules use the same `useACMEHost`
  # attribute to configure this.
  vhostUsesCert = vhost: vhost.useACMEHost == cfg.domain;

  nginxVhosts = optionals cfgNginx.enable (
    mapAttrsToList
      (attr: v: {
        vhost = "nginx: ${attr}";
        names = [ (if v.serverName != null then v.serverName else attr) ]
          ++ v.serverAliases;
      })
      (filterAttrs (_: vhostUsesCert) cfgNginx.virtualHosts)
  );

  caddyVhosts = optionals cfgCaddy.enable (
    mapAttrsToList
      (attr: v: {
        vhost = "caddy: ${attr}";
        names = [ v.hostName ] ++ v.serverAliases;
      })
      (filterAttrs (_: vhostUsesCert) cfgCaddy.virtualHosts)
  );

  proxyVhosts = nginxVhosts ++ caddyVhosts;

  # Determine which reverse proxies need their users added to the ACME group.
  proxyUsers =
    optional (nginxVhosts != [ ]) cfgNginx.user
    ++ optional (caddyVhosts != [ ]) cfgCaddy.user;

  # Every subject alternate name (SAN) is included in the certificate.
  allSANs = [ cfg.domain "*.${cfg.domain}" ] ++ cfg.extraDomainNames;

  # Returns `true` if the address `addr` matches any SAN in the certificate.
  isValidForAddr = addr:
    let
      # Caddy site addresses may carry a scheme and port, so strip those out to
      # reduce them to just the hostname.
      #
      # An unparseable address is left as is, and will (correctly) be considered
      # "not covered by any SAN".
      hostname =
        let m = builtins.match "([a-z]+://)?([^:/]+)(:[0-9]+)?" addr;
        in if m == null then addr else elemAt m 1;
      # Returns `true` if the SAN `pattern` is valid for `name`. A wildcard SAN
      # matches exactly one label so `*.example.com` covers `a.example.com` but
      # neither `example.com` nor `a.b.example.com`.
      includesHostname = pattern:
        if hasPrefix "*." pattern then
          let suffix = removePrefix "*" pattern; in
          hasSuffix suffix hostname && !(hasInfix "." (removeSuffix suffix hostname))
        else
          pattern == hostname;
    in
    any (includesHostname) allSANs;
in
{
  options.profiles.acme = {
    enable = mkEnableOption "wildcard ACME TLS certificate (DNS-01)";

    dnsProvider = mkOption {
      type = types.str;
      example = "cloudflare";
      description = ''
        The lego DNS provider name used for the DNS-01 challenge. See the
        [lego documentation](https://go-acme.github.io/lego/dns/) for the names
        of supported providers, and for the required credentials to include in
        `credentialFiles`.
      '';
    };

    credentialFiles = mkOption {
      type = types.attrsOf types.path;
      example = literalExpression ''
        { CF_DNS_API_TOKEN_FILE = config.age.secrets.cloudflare-dns-token.path; }
      '';
      description = ''
        Files holding the DNS provider's credentials. The keys in this attrset
        are the names of the lego environment variables to set.

        Each environment variable name must end in `_FILE` (or `_PATH`), which
        tells lego to read the value from the file. The files are passed to the
        issuing service through systemd `LoadCredential`, so they need not be
        readable by the `acme` user.
      '';
    };

    domain = mkOption {
      type = types.str;
      example = "home.example.com";
      description = ''
         The base domain for which to obtain a certificate. The certificate will
         be valid for this domain and `*.<domain>` (i.e. subdomains one label
         deep).

        This is also the cert's name in `security.acme.certs` and the value
        vhosts should use for `useACMEHost`.
      '';
    };

    extraDomainNames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional names to include in the certificate, for hosts the wildcard
        does not cover (e.g. `*.b.<domain>` or `*.example.org`). Wildcard
        entries cover one label, like the built-in `*.<domain>`.

        Note that any literal domain names added here are published publicly in
        Certificate Transparency logs, which reveals that the domain exists.
        Prefer a wildcard if keeping LAN domains private is important.
      '';
    };

    email = mkOption {
      type = types.str;
      default = "hawk.weisman+acme@gmail.com";
      description = "Contact address registered with the ACME account.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Users granted read access to the certificate's private key, in
        addition to the nginx or Caddy user when they have a vhost using the
        certificate.

        This is not needed for services that run as root. The users must
        exist and must not be `DynamicUser`s.
      '';
    };

    reloadServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "zrepl.service" ];
      description = ''
        Systemd units to `reload-or-restart` after the certificate is renewed.
        Caddy vand nginx hosts using the certificate are added automatically.
        This is intended for other services which also need a certificate.
      '';
    };

    directory = mkOption {
      type = types.path;
      readOnly = true;
      default = config.security.acme.certs.${cfg.domain}.directory;
      defaultText = literalExpression "config.security.acme.certs.\${config.profiles.acme.domain}.directory";
      description = ''
        The directory holding `cert.pem`, `chain.pem`, `fullchain.pem`, and
        `key.pem`. This is used when services other than Caddy or nginx also
        consume an ACME certificate.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfgNginx.enable && cfgCaddy.enable);
        message = ''
          profiles.acme: `services.nginx` and `services.caddy` are both
          enabled, but both bind ports 80 and 443. Enable only one reverse
          proxy per host!
        '';
      }
    ] ++ concatMap
      ({ vhost, names }:
        let uncovered = filter (n: !isValidForAddr n) names; in
        optional (uncovered != [ ]) {
          assertion = false;
          message = ''
            profiles.acme: ${vhost} uses the `${cfg.domain}` certificate, but
            the certificate does not cover ${concatStringsSep ", " uncovered}.
            The certificate is issued for: ${concatStringsSep ", " allSANs}.
            Note that a wildcard certificate covers one label only.
          '';
        })
      proxyVhosts;


    security.acme = {
      acceptTerms = true;
      email = cfg.email;

      certs.${cfg.domain} = {
        inherit group;
        domain = cfg.domain;
        extraDomainNames = [ "*.${cfg.domain}" ] ++ cfg.extraDomainNames;
        reloadServices = cfg.reloadServices;

        # The DNS-01 settings are per-cert rather than `defaults`, so that they
        # don't leak onto unrelated certs on the host (e.g. an HTTP-01 cert from
        # a public vhost with `enableACME`).
        inherit (cfg) dnsProvider credentialFiles;

        # Resolve through Cloudflare's resolver rather than the system's. On my
        # LAN the system resolver is split-horizon, and may not see the
        # challenge record that lives in the public zone.
        dnsResolver = "1.1.1.1:53";

        # If the DNS provider is Cloudflare, use a fixed 30-second wait for the
        # TXT record to propagate, rather than polling for the record's
        # existence.
        #
        # This is a (really unfortunate) workaround for an issue lego's
        # propagation detection when using Cloudflare DNS. Lego queries for the
        # TXTrecord immediately after the API call that creates it. If this
        # query occurs before Cloudflare has actually published the record, the
        # authoritative server responds with NODATA, and then Cloudflare then
        # serves that cached negative answer to every later query for 1800
        # seconds (the zone's SOA minimum). This includes both the authoritative
        # servers' and including from other networks, so the check fails for its
        # timeout and issuance never succeeds.
        #
        # By just waiting for a fixed 30 seconds, nothing queries for the record
        # before Let's Encrypt and there should be no cached negative response.
        # Luckily, Cloudflare's propagation is pretty quick, so 30s seems to be
        # long enough.The wait runs once per challenge, so issuance takes about
        # 30s per SAN.
        #
        # This replaces both the authoritative and recursive checks lego usually
        # performs.
        #
        # TODO(eliza): This kinda sucks. It would be nice to figure out some way
        # to make it not do that...
        extraLegoFlags = mkIf (cfg.dnsProvider == "cloudflare")
          [ "--dns.propagation.wait" "30s" ];
      };
    };

    users.users = genAttrs (unique (cfg.users ++ proxyUsers))
      (_: { extraGroups = [ group ]; });
  };
}
