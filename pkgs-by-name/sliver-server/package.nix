{ lib, stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "sliver-server";
  version = "1.7.3";

  src = fetchFromGitHub {
    owner = "BishopFox";
    repo = "sliver";
    rev = "v${version}";
    hash = "sha256-3FYiDQiirc/VE9HEDny7/7x69XHQbylXPuKpcNJgLHw=";
  };

  vendorHash = null;

  ldflags = [
    "-s" "-w"
    "-X github.com/bishopfox/sliver/client/command/update.SliverPublicKey=RWTZPg959v3b7tLG7VzKHRB1/QT+d3c71Uzetfa44qAoX5rH7mGoQTTR"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryPublicKey=RWSBpxpRWDrD7Fe+VvRE3c2VEDC2NK80rlNCj+BX0gz44Xw07r6KQD9L"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryRepoURL=https://api.github.com/repos/sliverarmory/armory/releases"
  ];

  preBuild = let
    os = if stdenv.hostPlatform.isLinux then "linux"
      else if stdenv.hostPlatform.isDarwin then "darwin"
      else "windows";
    arch = if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  in ''
    mkdir -p server/assets/fs/${os}/${arch}
    printf '\x50\x4b\x05\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
      > server/assets/fs/src.zip
    touch server/assets/fs/${os}/${arch}/PLACEHOLDER
  '';

  buildPhase = ''
    runHook preBuild
    CGO_ENABLED=0 go build -mod=vendor -trimpath \
      -tags "go_sqlite,server" \
      -ldflags '${lib.strings.concatStringsSep " " ldflags}' \
      -o sliver-server ./server
    runHook postBuild
  '';

  installPhase = ''
    install -Dm755 sliver-server $out/bin/sliver-server
  '';

  checkPhase = "";

  meta = with lib; {
    description = "Sliver server - Command & Control server";
    homepage = "https://github.com/BishopFox/sliver";
    changelog = "https://github.com/BishopFox/sliver/releases/tag/v${version}";
    license = licenses.gpl3Only;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
