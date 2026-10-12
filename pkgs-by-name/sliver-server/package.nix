{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  zip,
  go_1_26,
  inputs,
}:
let
  # Source is the `sliver` flake input (see flake.nix). Bump it with
  # `nix flake update sliver` instead of editing rev/hash here.
  # pkgs-by-name-for-flake-parts exposes the flake `inputs` attrset to every
  # package function, which is how this argument gets filled in.
  src = inputs.sliver.outPath;

  # Versions of the toolchains Sliver ships as build assets, read from the
  # pinned source rather than hardcoded so they track upstream the same way the
  # rev does. Upstream calls these `goVersion` and `garbleVersion` in
  # util/assets/constants.go; the constants are tab-indented and "goVersion" is
  # not a substring of "garbleVersion", so matching on the name alone is safe.
  constFromAssets =
    name:
    let
      lines = lib.splitString "\n" (builtins.readFile (src + "/util/assets/constants.go"));
      hits = lib.filter (line: lib.hasInfix name line) lines;
      quoted =
        if hits == [ ] then
          null
        else
          builtins.match ''.*"([^"]+)".*'' (lib.head hits);
    in
    if quoted == null then
      throw "sliver-server: could not parse ${name} from util/assets/constants.go"
    else
      builtins.head quoted;

  goAssetsVersion = constFromAssets "goVersion";

  # garble rewrites the standard library sources of the GOROOT it is handed, so
  # it has to match the Go toolchain shipped above. Upstream tracks this with
  # `garbleVersion`, which moves in lockstep with `goVersion`.
  garbleAssetsVersion = constFromAssets "garbleVersion";

  # sha256 of the official Go tarballs, keyed by version and arch. This is the
  # one hash that cannot come from the flake input, since it is content from a
  # *different* project (dl.google.com). It only needs a new entry when upstream
  # Sliver bumps its own `goVersion` - and if that happens without one, the throw
  # below tells you exactly what to add.
  goTarballHashes = {
    "1.26.6" = {
      amd64 = "sha256-cI7/t3S+gjdXDQrdFjIlq7369PyiiyYR3xZ766T+74k=";
      arm64 = "sha256-0FB+np1/4BKq5XAQjL12wV3oeeFxMKuMuQ1NdEXLHy4=";
    };
  };

  # Upstream ships a prebuilt garble release binary per platform
  # (util/assets/garble.go). We build the same tag from source instead, so that
  # the hash can be pinned by the flake rather than by a mutable release asset.
  # Same guard shape as goTarballHashes: a missing entry names itself.
  garbleHashes = {
    "1.26.6" = "sha256-ndkWliDzJLZFyhEikzu8UHkLyiJylHzmjd16WIakvak=";
  };

  garbleSrcHash =
    garbleHashes.${garbleAssetsVersion} or (throw ''
      sliver-server: pinned Sliver wants garble v${garbleAssetsVersion}, which has no
      entry in garbleHashes. Add the source tarball's sha256 as
      garbleHashes."${garbleAssetsVersion}", e.g. via:
        nix-prefetch-url --unpack https://github.com/moloch--/garble/archive/refs/tags/v${garbleAssetsVersion}.tar.gz
      (or just let `nix build` report the correct hash for you).
    '');

  goArch =
    if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";

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
        url = "https://dl.google.com/go/go${goAssetsVersion}.linux-${goArch}.tar.gz";
        hash =
          let
            entry = goTarballHashes.${goAssetsVersion} or null;
          in
          if entry == null then
            throw ''
              sliver-server: pinned Sliver wants go${goAssetsVersion}, which has no
              entry in goTarballHashes. Add the tarball's sha256 as
              goTarballHashes."${goAssetsVersion}".${goArch}, e.g. via:
                nix-prefetch-url --unpack https://dl.google.com/go/go${goAssetsVersion}.linux-${goArch}.tar.gz
              (or just let `nix build` report the correct hash for you).
            ''
          else
            entry.${goArch};
      }
    else null;
in
buildGoModule rec {
  pname = "sliver-server";
  version = "1.7.7";

  inherit src;

  vendorHash = null;

  # Linux shellcode is produced by compiling a `go build -buildmode=c-shared`
  # object and handing it to malasada, which turns the .so into position-
  # independent shellcode. The C compiler is zig (lld), which - unlike GNU ld -
  # does not store an in-image pointer directly in .init_array: it leaves the
  # slot zero and records the link-time address as an R_X86_64_RELATIVE
  # addend. Upstream extractInitVaddrs64() reads .init_array straight out of
  # the file, so it concluded the object had no initializers and emitted an
  # entry stub that calls none. .init_array[0] is `_rt0_amd64_linux_lib`, the
  # Go runtime bootstrap, and stage0's hand-off to ld.so does not run the main
  # map's DT_INIT_ARRAY either, so nothing ever started the runtime: the stub
  # called the export (StartW), which blocked forever in
  # _cgo_wait_runtime_init_done waiting on runtime_init_cond.
  #
  # The patch resolves init_array slots through their R_X86_64_RELATIVE
  # addends, falling back to the inline value when the linker wrote one, so it
  # behaves the same under both linkers. Worth sending upstream to
 # github.com/sliverarmory/malasada.
  patches = [./malasada-init-array.patch];

  garble = buildGoModule {
    pname = "garble";
    version = garbleAssetsVersion;
    src = fetchFromGitHub {
      owner = "moloch--";
      repo = "garble";
      rev = "v${garbleAssetsVersion}";
      hash = garbleSrcHash;
    };
    vendorHash = "sha256-F0Jc15ulA+qRDZu5W3FU9dZ+oXq8lGXP4dQeWnZwYbk=";
    # Pin the toolchain generation rather than inheriting stdenv.go, which
    # nixpkgs bumps independently of the sliver pin. garble is version-locked
    # to the Go toolchain it is shipped against.
    go = go_1_26;
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
    "-X github.com/bishopfox/sliver/client/version.GitCommit=${inputs.sliver.rev}"
    "-X github.com/bishopfox/sliver/client/version.CompiledAt=$(date +%s)"
    "-X github.com/bishopfox/sliver/server/version.Version=${version}"
    "-X github.com/bishopfox/sliver/server/version.GitCommit=${inputs.sliver.rev}"
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
