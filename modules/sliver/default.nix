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
