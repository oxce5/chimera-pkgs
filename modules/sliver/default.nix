{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.sliver;
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

      # cgo falls back to `gcc` for native builds. Garble passes `-buildid=` to the
      # Go linker, which suppresses the `--build-id` note; with Nix's binutils the
      # resulting c-shared .so then has no PT_NOTE/PT_PHDR and malasada cannot
      # convert it to shellcode. Prepending -Wl,--build-id restores a PT_NOTE.
      path = let
        go_1_26_6 = pkgs.go_1_26.overrideAttrs (old: rec {
          version = "1.26.6";
          src = pkgs.fetchurl {
            url = "https://go.dev/dl/go${version}.src.tar.gz";
            hash = "sha256-oHIcVMaIkBRI13rZs+x+p8R0cwdV/4kTgukuy5P/LLE=";
          };
        });
      in
      with pkgs; [
        git
        (writeShellScriptBin "gcc" ''
          exec "${gcc}/bin/gcc" -Wl,--build-id "$@"
        '')
        go_1_26_6
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
