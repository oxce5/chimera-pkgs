{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "sliver-client";
  version = "1.7.3";

  src = fetchFromGitHub {
    owner = "BishopFox";
    repo = "sliver";
    rev = "v${version}";
    hash = "sha256-3FYiDQiirc/VE9HEDny7/7x69XHQbylXPuKpcNJgLHw=";
  };

  vendorHash = null;

  ldflags = [
    "-s -w"
    "-X github.com/bishopfox/sliver/client/command/update.SliverPublicKey=RWTZPg959v3b7tLG7VzKHRB1/QT+d3c71Uzetfa44qAoX5rH7mGoQTTR"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryPublicKey=RWSBpxpRWDrD7Fe+VvRE3c2VEDC2NK80rlNCj+BX0gz44Xw07r6KQD9L"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryRepoURL=https://api.github.com/repos/sliverarmory/armory/releases"
    "-X github.com/bishopfox/sliver/client/version.Version=${version}"
    "-X github.com/bishopfox/sliver/client/version.GitCommit=${src.rev}"
    "-X github.com/bishopfox/sliver/client/version.CompiledAt=$(date +%s)"
  ];

  buildPhase = ''
    runHook preBuild
    CGO_ENABLED=0 go build -mod=vendor -trimpath \
      -tags "go_sqlite,client" \
      -ldflags "${lib.strings.concatStringsSep " " ldflags}" \
      -o sliver-client ./client
    runHook postBuild
  '';

  installPhase = ''
    install -Dm755 sliver-client $out/bin/sliver-client
  '';

  checkPhase = "";

  meta = with lib; {
    mainProgram = "sliver-client";
    description = "Sliver client - Operator CLI for Sliver C2";
    homepage = "https://github.com/BishopFox/sliver";
    changelog = "https://github.com/BishopFox/sliver/releases/tag/v${version}";
    license = licenses.gpl3Only;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
