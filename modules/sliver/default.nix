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
      type = lib.types.package;
      default = pkgs.sliver;
      defaultText = lib.literalExpression "pkgs.sliver";
      description = "Sliver package to use (provides sliver-server and sliver-client).";
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

  config = lib.mkIf cfg.enable {
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

      # When an implant's GOOS/GOARCH matches the server's, sliver never calls
      # findCrossCompilers() (see server/generate/binaries.go) and so leaves CC
      # empty, letting cgo fall back to `gcc` from PATH. That would pick up Nix's
      # gcc wrapper, which stamps the Nix store's glibc into PT_INTERP and makes
      # the implant refuse to start on any host without that store path.
      #
      # Shim `gcc` to the zig that sliver unpacks from its own assets into
      # $SLIVER_ROOT_DIR/zig (server/assets: GetZigDir, untarSkipTopLevel drops
      # the archive's top-level dir, so the binary sits directly in `zig/`).
      # Targeting the *gnu* flavour keeps today's dynamically linked,
      # glibc-dependent implants, but with the FHS-compliant
      # /lib64/ld-linux-x86-64.so.2 interpreter. Note this is the only place the
      # compiler is chosen for native builds; cross-arch builds already get zig
      # (musl) from sliver itself.
      #
      # -Wl,--build-id is kept for the c-shared -> shellcode path: garble passes
      # `-buildid=` to the Go linker, suppressing the note, and without a PT_NOTE
      # malasada cannot convert the .so to shellcode.
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
        ExecStart = "${lib.getExe cfg.package} daemon --force";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = lib.strings.removePrefix "/var/lib/" cfg.dataDir;
        StateDirectoryMode = "0700";
        UMask = "0077";
      };
    };
  };
}
