{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  zip,
  go_1_26,
}:
buildGoModule rec {
  pname = "sliver-server";
  version = "1.7.7";

  src = fetchFromGitHub {
    owner = "BishopFox";
    repo = "sliver";
    rev = "0aa7e5bf962414823f12c3a8ea1f667f61b19ce2";
    hash = "sha256-yIpdbHVT+yiQrncoulW75+431T7z6akvnFhbSRglpDk=";
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

  # Version of the Go toolchain Sliver ships as a build asset. Keep in sync
  # with util/assets/constants.go (goVersion) upstream.
  goAssetsVersion = "1.26.6";

  # Upstream Sliver downloads a *pristine* Go toolchain from dl.google.com for
  # the server to build implants with (see util/assets/go.go). We have to do the
  # same on Linux: nixpkgs patches Go's bootstrap so that
  # src/internal/buildcfg/zbootstrap.go declares
  #   DefaultGO_LDSO = /nix/store/...-glibc-*/lib/ld-linux-x86-64.so.2
  # which cmd/link then uses as PT_INTERP for internally linked cgo binaries
  # (cmd/link/internal/ld/elf.go). Bundling nixpkgs' Go therefore stamps every
  # generated implant with a Nix store interpreter, so it only runs on hosts
  # that happen to have that store path. The official tarball leaves GO_LDSO
  # empty, so the interpreter is supplied by the bundled zig cc instead - which
  # gives the FHS-compliant /lib64/ld-linux-x86-64.so.2.
  #
  # Darwin is left on nixpkgs' Go: it has no bearing on the implants produced
  # there, and it avoids pulling in two more ~80MB tarball hashes.
  goTarGz =
    if stdenv.hostPlatform.isLinux then
      fetchurl {
        url =
          if stdenv.hostPlatform.isAarch64
          then "https://dl.google.com/go/go${goAssetsVersion}.linux-arm64.tar.gz"
          else "https://dl.google.com/go/go${goAssetsVersion}.linux-amd64.tar.gz";
        hash =
          if stdenv.hostPlatform.isAarch64
          then "sha256-0FB+np1/4BKq5XAQjL12wV3oeeFxMKuMuQ1NdEXLHy4="
          else "sha256-cI7/t3S+gjdXDQrdFjIlq7369PyiiyYR3xZ766T+74k=";
      }
    else null;

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

    ${lib.optionalString (goTarGz != null) ''
      tar -xf ${goTarGz} -C $TMPDIR
    ''}
    ${lib.optionalString (goTarGz == null) ''
      cp -r ${go_1_26}/share/go $TMPDIR/go
    ''}
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
