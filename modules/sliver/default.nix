{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.sliver;

  # zig target triple matching the server's own platform, used for native
  # (same-arch) implant builds where sliver defers to `gcc` from PATH.
  nativeTarget =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      "aarch64-linux-gnu"
    else
      "x86_64-linux-gnu";
in {
  options.services.sliver = {
    enable = lib.mkEnableOption "Sliver C2 server";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      # There is no `pkgs.sliver` to point at, and defaulting to a
      # non-existent attribute throws whenever this module is imported
      # without the flake's `nixosModules.sliver` wrapper. Require it instead:
      # the flake supplies it via `lib.mkDefault`.
      default = null;
      defaultText = lib.literalExpression "null";
      description = ''
        Sliver server package to run. This flake's `nixosModules.sliver`
        sets it to `self.packages.<system>.sliver-server` via `lib.mkDefault`,
        so most users never set it. Required when the module is imported
        directly.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sliver";
      description = "Root data directory. Used as the sliver user's home, so sliver defaults to ~/.sliver inside it.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sliver";
      description = "User to run the service as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "sliver";
      description = "Group to run the service as.";
    };

    portfwdAddresses = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?");
      default = ["240.0.0.1/32"];
      example = ["240.0.0.1/32" "240.0.0.2/32"];
      description = ''
        IPv4 addresses to assign to `lo` so `portfwd --bind` can use them.
        `portfwd` listeners are created by the interactive client process, not
        the server daemon, and Burp/browsers bypass the proxy for 127.0.0.0/8.
        Binding a fake address from the reserved 240.0.0.0/4 range is what
        makes tunneled traffic interceptable, e.g.
        `portfwd add --bind 240.0.0.1:443 --remote <target>:443`.

        Assigning a wider prefix (e.g. `240.0.0.1/24`) makes the whole prefix
        local on lo, so any address in it can be bound and reaches the
        listener. Note the kernel installs the prefix as a local route on lo,
        which shadows tunnel routes for the same range.
      '';
    };

    allowNonLocalBind = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set `net.ipv4.ip_nonlocal_bind = 1` so listeners may bind IPv4
        addresses that are not assigned to any local interface. Needed for
        addresses that only have a route - e.g. an arbitrary address in a
        ligolo-ng style tunnel range; addresses covered by a
        `portfwdAddresses` prefix are already local to lo.
      '';
    };

    unprivilegedPortStart = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = 80;
      description = ''
        Value for `net.ipv4.ip_unprivileged_port_start`, letting unprivileged
        processes bind 80/443. `portfwd` runs in the sliver-client process and
        this module cannot hand an interactive process file capabilities, so
        the sysctl is used instead of `CAP_NET_BIND_SERVICE`. This applies
        system-wide: any local process may bind ports at or above the given
        value. Set to null to leave the sysctl untouched.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # There is no pkgs.sliver for this to default to, so the flake supplies
      # the package. Report that as a readable error rather than letting
      # `lib.getExe null` fail during evaluation.
      assertions = [
        {
          assertion = cfg.package != null;
          message = "services.sliver.package must be set when services.sliver.enable is true.";
        }
      ];
    })

    (lib.mkIf (cfg.enable && cfg.package != null) {
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
      };

      users.groups.${cfg.group} = {};

      # Host-level enablement for portfwd, whose listeners live in the
      # interactive client rather than the daemon: aliasing the address on lo
      # makes the bind succeed and keeps the traffic local instead of letting
      # it follow the default route off the box, and the sysctls cover
      # addresses that are merely routed (ligolo-style tunnels) plus
      # unprivileged binds of 80/443.
      #
      # `networking.interfaces.lo` is the declarative way, but on the scripted
      # networking backend the generated `network-addresses-lo.service` gets an
      # empty WantedBy (the device dependency for lo is empty) and never runs,
      # so the address silently never appears. Use our own oneshot instead; it
      # works on both backends.
      systemd.services.sliver-portfwd-aliases = lib.mkIf (cfg.portfwdAddresses != []) {
        description = "Sliver portfwd loopback aliases";
        wantedBy = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart =
            map (cidr: "${pkgs.iproute2}/bin/ip addr replace ${cidr} dev lo")
            cfg.portfwdAddresses;
        };
      };

      boot.kernel.sysctl = {
        "net.ipv4.ip_nonlocal_bind" = lib.mkIf cfg.allowNonLocalBind 1;
        "net.ipv4.ip_unprivileged_port_start" =
          lib.mkIf (cfg.unprivilegedPortStart != null) cfg.unprivilegedPortStart;
      };

      systemd.services.sliver = {
        description = "Sliver";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];

        # Sliver leaves CC empty for same-arch implants and lets cgo fall back
        # to `gcc` from PATH - which on NixOS is the Nix gcc wrapper, stamping a
        # Nix store PT_INTERP. Shim it to sliver's own bundled zig instead.
        # Load-bearing; see AGENTS.md, "why these deviations exist".
        #
        # -Wl,--build-id keeps a PT_NOTE on the c-shared -> shellcode path,
        # which garble's `-buildid=` would otherwise suppress and malasada needs.
        path = [
          pkgs.git
          (pkgs.writeShellScriptBin "gcc" ''
            # Mirrors server/assets.GetRootAppDir() + GetZigDir().
            zig="''${SLIVER_ROOT_DIR:-$HOME/.sliver}/zig/zig"
            if [ ! -x "$zig" ]; then
              echo "sliver: zig not found at $zig - has the server unpacked its assets yet?" >&2
              exit 127
            fi
            exec "$zig" cc -target ${nativeTarget} -Wl,--build-id "$@"
          '')
        ];

        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "3";
          User = cfg.user;
          Group = cfg.group;
          # No --force: assets.Setup() already gates on the on-disk version
          # file vs the GitCommit we bake in via ldflags, so a restart neither
          # re-extracts ~100 MB of go/ and zig/ nor overwrites
          # operator-edited traffic encoders (assets-helpers.go only writes
          # those when missing, unless forced).
          ExecStart = "${lib.getExe cfg.package} daemon";
          WorkingDirectory = cfg.dataDir;
          StateDirectory = lib.strings.removePrefix "/var/lib/" cfg.dataDir;
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
      };
    })
  ];
}
