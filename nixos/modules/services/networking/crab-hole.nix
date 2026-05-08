{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.crab-hole;

  settingsFormat = pkgs.formats.toml { };

  hasOldTrustNx =
    cfg.settings ? upstream
    && cfg.settings.upstream ? name_servers
    && lib.any (ns: ns ? trust_nx_responses) cfg.settings.upstream.name_servers;

  hasOldApiListenPort =
    cfg.settings ? api
    && ((cfg.settings.api ? listen) || (cfg.settings.api ? port))
    && !(cfg.settings.api ? listener);

  updatedSettings =
    let
      rewriteNameServer =
        ns:
        if (ns ? trust_nx_responses) && !(ns ? trust_negative_responses) then
          (removeAttrs ns [ "trust_nx_responses" ])
          // {
            trust_negative_responses = ns.trust_nx_responses;
          }
        else
          ns;

      rewriteUpstream =
        upstream:
        if upstream ? name_servers then
          upstream // { name_servers = map rewriteNameServer upstream.name_servers; }
        else
          upstream;

      mkListener =
        listen: port:
        let
          host = toString listen;
          needsBrackets = lib.hasInfix ":" host && !(lib.hasPrefix "[" host) && !(lib.hasSuffix "]" host);
        in
        "${if needsBrackets then "[${host}]" else host}:${toString port}";

      rewriteApi =
        api:
        if (api ? listener) then
          api
        else if (api ? listen) && (api ? port) then
          (removeAttrs api [
            "listen"
            "port"
          ])
          // {
            listener = mkListener api.listen api.port;
          }
        else
          api;

      rewriteSettings =
        s:
        (if s ? upstream then s // { upstream = rewriteUpstream s.upstream; } else s)
        // (if s ? api then { api = rewriteApi s.api; } else { });
    in
    rewriteSettings cfg.settings;

  checkConfig =
    file:
    pkgs.runCommand "check-config"
      {
        nativeBuildInputs = [
          cfg.package
          pkgs.cacert
          pkgs.dig
        ];
      }
      ''
        ln -s ${file} $out

        ln -s ${file} ./config.toml
        export CRAB_HOLE_DIR=$(pwd)

        ${lib.getExe cfg.package} validate-config
      '';
in
{
  options = {
    services.crab-hole = {
      enable = lib.mkEnableOption "Crab-hole Service";

      package = lib.mkPackageOption pkgs "crab-hole" { };

      supplementaryGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "acme" ];
        description = "Adds additional groups to the crab-hole service. Can be useful to prevent permission issues.";
      };

      settings = lib.mkOption {
        description = "Crab-holes config. See big example <https://github.com/LuckyTurtleDev/crab-hole/blob/main/example-config.toml>";

        example = {
          downstream = [
            {
              listen = "localhost";
              port = 8080;
              protocol = "udp";
            }
            {
              certificate = "dns.example.com.crt";
              dns_hostname = "dns.example.com";
              key = "dns.example.com.key";
              listen = "[::]";
              port = 8055;
              protocol = "https";
              timeout_ms = 3000;
            }
          ];
          api = {
            admin_key = "1234";
            listener = "127.0.0.1:8080";
            show_doc = true;
          };
          blocklist = {
            allow_list = [
              "file:///allowed.txt"
            ];
            include_subdomains = true;
            lists = [
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts"
              "https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt"
              "file:///blocked.txt"
            ];
          };
          upstream = {
            name_servers = [
              {
                protocol = "tls";
                socket_addr = "[2606:4700:4700::1111]:853";
                tls_dns_name = "1dot1dot1dot1.cloudflare-dns.com";
                trust_negative_responses = false;
              }
              {
                protocol = "tls";
                socket_addr = "1.1.1.1:853";
                tls_dns_name = "1dot1dot1dot1.cloudflare-dns.com";
                trust_negative_responses = false;
              }
            ];
            options = {
              validate = true;
            };
          };
        };

        type = lib.types.submodule {
          freeformType = settingsFormat.type;
          options = {
            blocklist =
              let
                listOption =
                  name:
                  lib.mkOption {
                    type = lib.types.listOf (lib.types.either lib.types.str lib.types.path);
                    default = [ ];
                    description = "List of ${name}. If files are added via url, make sure the service has access to them!";
                    apply = map (v: if builtins.isPath v then "file://${v}" else v);
                  };
              in
              {
                include_subdomains = lib.mkEnableOption "Include subdomains";
                lists = listOption "blocklists";
                allow_list = listOption "allowlists";
              };
          };
        };
      };

      configFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          The config file of crab-hole.

          If files are added via url, make sure the service has access to them.
          Setting this option will override any configuration applied by the settings option.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Warning due to config change in crab-hole 0.2.0
    warnings =
      lib.optional hasOldTrustNx ''
        `services.crab-hole.settings.upstream.name_servers.*.trust_nx_responses` has been renamed to `services.crab-hole.settings.upstream.name_servers.*.trust_negative_responses`.
      ''
      ++ lib.optional hasOldApiListenPort ''
        `services.crab-hole.settings.api.listen`/`port` has been renamed to `services.crab-hole.settings.api.listener`.
      '';

    services.crab-hole.configFile = lib.mkDefault (
      checkConfig (settingsFormat.generate "crab-hole.toml" updatedSettings)
    );
    environment.etc."crab-hole.toml".source = cfg.configFile;

    systemd.services.crab-hole = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      description = "Crab-hole dns server";
      environment.HOME = "/var/lib/crab-hole";
      restartTriggers = [ cfg.configFile ];
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        SupplementaryGroups = cfg.supplementaryGroups;

        StateDirectory = "crab-hole";
        WorkingDirectory = "/var/lib/crab-hole";

        ExecStart = lib.getExe cfg.package;

        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";

        Restart = "on-failure";
        RestartSec = 1;
      };
    };
  };

  meta.maintainers = [
    lib.maintainers.NiklasVousten
  ];
  # Readme from upstream
  meta.doc = ./crab-hole.md;
}
