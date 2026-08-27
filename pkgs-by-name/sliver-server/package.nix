{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  go,
  zip,
}:
buildGoModule rec {
  pname = "sliver-server";
  version = "1.7.4";

  src = fetchFromGitHub {
    owner = "BishopFox";
    repo = "sliver";
    rev = "09b0540e75a1d4a38460092b3e52d6e6c4d3bfed";
    hash = "sha256-f0jl+hV4j534bwUprQPFu4wbaoSWS3cEe2sU/KTEB5s=";
  };

  vendorHash = null;

  garble = buildGoModule {
    pname = "garble";
    version = "1.26.6";
    src = fetchFromGitHub {
      owner = "moloch--";
      repo = "garble";
      rev = "542a43149f26e75e6a0c7327a68aab63a9c60ed7";
      hash = "sha256-ndkWliDzJLZFyhEikzu8UHkLyiJylHzmjd16WIakvak=";
    };
    vendorHash = "sha256-F0Jc15ulA+qRDZu5W3FU9dZ+oXq8lGXP4dQeWnZwYbk=";
    ldflags = ["-s -w"];
    buildPhase = ''
      runHook preBuild
      # CGO_ENABLED=0 so garble is statically linked (no Nix glibc loader
      # dependency at runtime on the target machine).
      CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o garble .
      runHook postBuild
    '';
    installPhase = ''
      install -Dm755 garble $out/bin/garble
    '';
    checkPhase = "";
    meta.mainProgram = "garble";
  };

  zigTarXz = fetchurl {
    url = "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz";
    hash = "sha256-AqonDxg9onbltZILHaxEpj8aSeVQUOveOuzJ64L5Mjk=";
  };

  preBuild = let
    os =
      if stdenv.hostPlatform.isLinux
      then "linux"
      else if stdenv.hostPlatform.isDarwin
      then "darwin"
      else "windows";
    arch =
      if stdenv.hostPlatform.isAarch64
      then "arm64"
      else "amd64";
  in ''
    mkdir -p server/assets/fs/${os}/${arch}

    cp -r ${go}/share/go $TMPDIR/go
    chmod -R +w $TMPDIR/go

    rm -rf $TMPDIR/go/api $TMPDIR/go/doc $TMPDIR/go/misc $TMPDIR/go/test
    rm -f $TMPDIR/go/{AUTHORS,CONTRIBUTORS,PATENTS,VERSION,favicon.ico,robots.txt,SECURITY.md,CONTRIBUTING.md,README.md}

    (cd $TMPDIR/go && ${zip}/bin/zip -r -q $OLDPWD/server/assets/fs/src.zip src/)

    rm -rf $TMPDIR/go/src
    rm -f $TMPDIR/go/pkg/tool/${os}_${arch}/{doc,tour,test2json}

    (cd $TMPDIR && ${zip}/bin/zip -r -q $OLDPWD/server/assets/fs/${os}/${arch}/go.zip go/)

    cp ${garble}/bin/garble server/assets/fs/${os}/${arch}/garble
    chmod +x server/assets/fs/${os}/${arch}/garble
    cp ${zigTarXz} server/assets/fs/${os}/${arch}/zig.tar.xz
  '';

  ldflags = [
    "-s -w"
    "-X github.com/bishopfox/sliver/client/command/update.SliverPublicKey=RWTZPg959v3b7tLG7VzKHRB1/QT+d3c71Uzetfa44qAoX5rH7mGoQTTR"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryPublicKey=RWSBpxpRWDrD7Fe+VvRE3c2VEDC2NK80rlNCj+BX0gz44Xw07r6KQD9L"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryRepoURL=https://api.github.com/repos/sliverarmory/armory/releases"
    "-X github.com/bishopfox/sliver/client/version.Version=${version}"
    "-X github.com/bishopfox/sliver/client/version.GitCommit=${src.rev}"
    "-X github.com/bishopfox/sliver/client/version.CompiledAt=$(date +%s)"
    "-X github.com/bishopfox/sliver/server/version.Version=${version}"
    "-X github.com/bishopfox/sliver/server/version.GitCommit=${src.rev}"
    "-X github.com/bishopfox/sliver/server/version.CompiledAt=$(date +%s)"
  ];

  buildPhase = ''
    runHook preBuild
    CGO_ENABLED=0 go build -mod=vendor -trimpath \
      -tags "go_sqlite,server" \
      -ldflags "${lib.strings.concatStringsSep " " ldflags}" \
      -o sliver-server ./server
    runHook postBuild
  '';

  installPhase = ''
    install -Dm755 sliver-server $out/bin/sliver-server
  '';

  checkPhase = "";

  meta = with lib; {
    mainProgram = "sliver-server";
    description = "Sliver server - Command & Control server";
    homepage = "https://github.com/BishopFox/sliver";
    changelog = "https://github.com/BishopFox/sliver/releases/tag/v${version}";
    license = licenses.gpl3Only;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
