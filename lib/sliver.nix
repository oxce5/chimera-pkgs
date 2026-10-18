# Shared plumbing for the Sliver packages.
#
# sliver-client and sliver-server are built from the same `sliver` flake input
# and carry the same public-key ldflags, so that lives here rather than being
# duplicated - and silently diverging - across both package.nix files.
#
# Args are forwarded verbatim by each package so the two stay symmetrical.
# Everything is lazy: a package only forces what it uses, so sliver-client does
# not drag in the toolchain derivations built for sliver-server.
{
  lib,
  stdenv,
  buildGoModule,
  fetchurl,
  fetchFromGitHub,
  inputs,
}:
let
  src = inputs.sliver.outPath;

  # Naming differs per toolchain: Go and Sliver's asset dirs use "arm64",
  # zig uses "aarch64".
  goArch = if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  zigArch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";

  assetOs =
    if stdenv.hostPlatform.isDarwin then "darwin" else "linux";

  # Sliver declares the versions of the toolchains it embeds as build assets.
  # Read them from the pinned source rather than hardcoding, so bumping the
  # `sliver` input cannot silently ship a mismatched toolchain.
  #
  # `builtins.match` is a *full-string* match, not a search, so this pattern
  # only accepts a line that is itself the declaration. An upstream comment or
  # doc line mentioning goVersion cannot shadow it. [[:space:]] rather than
  # [ \t] because an indented Nix string passes `\t` through unreduced and Nix's
  # regex engine does not understand the escape.
  constFromAssets =
    name:
    let
      pattern = "[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*";
      lines = lib.splitString "\n" (builtins.readFile (src + "/util/assets/constants.go"));
      declarations = lib.filter (line: builtins.match pattern line != null) lines;
    in
    if builtins.length declarations != 1 then
      throw "sliver: expected exactly one `${name}` declaration in util/assets/constants.go, found ${toString (builtins.length declarations)}"
    else
      builtins.head (builtins.match pattern (builtins.head declarations));

  goAssetsVersion = constFromAssets "goVersion";
  garbleAssetsVersion = constFromAssets "garbleVersion";
  zigAssetsVersion = constFromAssets "zigVersion";

  # Content hashes for the toolchains Sliver downloads at build time. These
  # cannot come from the flake input - they are bytes from dl.google.com and
  # ziglang.org, not from the sliver repo. A version bump without an entry here
  # fails loudly rather than substituting a stale toolchain.
  goTarballHashes = {
    "1.26.6" = {
      amd64 = "sha256-cI7/t3S+gjdXDQrdFjIlq7369PyiiyYR3xZ766T+74k=";
      arm64 = "sha256-0FB+np1/4BKq5XAQjL12wV3oeeFxMKuMuQ1NdEXLHy4=";
    };
    "1.27.2" = {
      amd64 = "sha256-7LrbmQkaP0bjH1+TSwaLGGTq+nmVIRs56t33aZYEX+U=";
      arm64 = "sha256-lPPjC443S8KF59rcEeCGVya5vG6FuEHMzqq8AhTGt8g=";
    };
  };

  # Keyed in zig's own arch naming (x86_64/aarch64), not Go's.
  zigHashes = {
    "0.15.2" = {
      x86_64 = "sha256-AqonDxg9onbltZILHaxEpj8aSeVQUOveOuzJ64L5Mjk=";
      aarch64 = "sha256-lY7X0eANDqdlkNJ2Zu+/epMigbPXugxrAbD/JkmPZn8=";
    };
  };

  garbleHashes = {
    "1.26.6" = "sha256-ndkWliDzJLZFyhEikzu8UHkLyiJylHzmjd16WIakvak=";
    "1.27.2" = "sha256-SBNoW6I18BFMOqvB/ud5FkPN0FAR/WpCqFkRu4Yo1A0=";
  };

  # A missing entry names itself, and prints the exact command that fixes it.
  hashOf =
    table:
    name:
    version:
    url:
    let
      entry = table.${version} or null;
    in
    if entry == null then
      throw ''
        sliver: pinned Sliver wants ${name} ${version}, which has no hash in
        ${name}Hashes. Add it, e.g. via:
          nix-prefetch-url --unpack ${url}
        (or just let `nix build` report the correct hash for you).
      ''
    else
      entry;

  # Per-arch tables, so an aarch64 build can never quietly take an amd64 hash.
  hashForArch =
    table:
    name:
    version:
    arch:
    url:
    let
      entry = hashOf table name version url;
    in
    entry.${arch} or (throw "sliver: ${name} ${version} has no ${arch} hash; add ${name}Hashes.${version}.${arch}");

  goTarGz =
    fetchurl {
      url = "https://dl.google.com/go/go${goAssetsVersion}.${assetOs}-${goArch}.tar.gz";
      hash = hashForArch goTarballHashes "go" goAssetsVersion goArch
        "https://dl.google.com/go/go${goAssetsVersion}.${assetOs}-${goArch}.tar.gz";
    };

  # The toolchain that builds sliver itself.
  #
  # Not nixpkgs' Go: upstream's go.mod demands a patch level newer than what
  # nixpkgs ships, and buildGoModule hardcodes GOTOOLCHAIN=local (it wins over
  # `env`, so it cannot be relaxed), which rules out letting Go fetch a newer
  # toolchain inside the sandbox anyway. So build with the very same pristine
  # tarball we already fetch for the embedded asset - one hash covers both uses,
  # and the version tracks upstream's `goVersion` automatically.
  #
  # buildGoModule reads ${go}/bin plus the GOOS/GOARCH/CGO_ENABLED attributes
  # off this derivation, so those are set explicitly below.
  goToolchain =
    stdenv.mkDerivation {
      pname = "go";
      version = goAssetsVersion;
      src = goTarGz;
      dontConfigure = true;
      installPhase = ''
        runHook preInstall
        # unpackPhase already strips the tarball's top-level `go/` directory,
        # so the working tree *is* the GOROOT; copy it to $out so that $out/bin/go
        # lands on PATH and GOROOT resolves to $out.
        mkdir -p $out
        cp -r ./. $out/
        runHook postInstall
      '';
      GOOS = assetOs;
      GOARCH = goArch;
      CGO_ENABLED = 1;
      meta.mainProgram = "go";
    };

  # Upstream downloads zig from a mirror list and verifies a minisign signature
  # (util/assets/zig.go). A pinned sha256 is the stronger, reproducible
  # equivalent - but it is per-platform, so the table above is what stops an
  # aarch64 build from quietly embedding the x86_64 tarball.
  zigTarXz =
    fetchurl {
      url = "https://ziglang.org/download/${zigAssetsVersion}/zig-${zigArch}-${assetOs}-${zigAssetsVersion}.tar.xz";
      hash = hashForArch zigHashes "zig" zigAssetsVersion zigArch
        "https://ziglang.org/download/${zigAssetsVersion}/zig-${zigArch}-${assetOs}-${zigAssetsVersion}.tar.xz";
    };

  # Upstream ships a prebuilt garble release binary per platform; we build the
  # same tag from source so the hash is pinned by the flake rather than by a
  # mutable release asset.
  # `.override`, not an attribute: buildGoModule is an extendMkDerivation, so a
  # plain `go = ...` is silently ignored and it falls back to nixpkgs' Go.
  garble =
    (buildGoModule.override { go = goToolchain; }) {
      pname = "garble";
      version = garbleAssetsVersion;
      src = fetchFromGitHub {
        owner = "moloch--";
        repo = "garble";
        rev = "v${garbleAssetsVersion}";
        hash = hashOf garbleHashes "garble" garbleAssetsVersion ''
          https://github.com/moloch--/garble/archive/refs/tags/v${garbleAssetsVersion}.tar.gz
        '';
      };
      # garble rewrites the standard library sources of the GOROOT it is handed,
      # so it must match the toolchain Sliver ships alongside it - hence the
      # override above. Vendor hash is per garble version; let the build report
      # the right one when bumping.
      vendorHash = "sha256-ZhT0aQnyodeGZ3R7jfn+9yyS9oilLevo4Itvplv4ypg=";
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

  # Release this flake tracks. Not derivable from the input: `sliver` is a
  # flake = false source, so the lock carries a rev but no tag.
  version = "1.7.7";

  gitCommit = inputs.sliver.rev;

  # Shared with upstream's Makefile LDFLAGS (default values there).
  publicKeyLdflags = [
    "-X github.com/bishopfox/sliver/client/command/update.SliverPublicKey=RWTZPg959v3b7tLG7VzKHRB1/QT+d3c71Uzetfa44qAoX5rH7mGoQTTR"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryPublicKey=RWSBpxpRWDrD7Fe+VvRE3c2VEDC2NK80rlNCj+BX0gz44Xw07r6KQD9L"
    "-X github.com/bishopfox/sliver/client/assets.DefaultArmoryRepoURL=https://api.github.com/repos/sliverarmory/armory/releases"
  ];

  clientVersionLdflags = [
    "-X github.com/bishopfox/sliver/client/version.Version=${version}"
    "-X github.com/bishopfox/sliver/client/version.GitCommit=${gitCommit}"
    "-X github.com/bishopfox/sliver/client/version.CompiledAt=$(date +%s)"
  ];

  serverVersionLdflags = [
    "-X github.com/bishopfox/sliver/server/version.Version=${version}"
    "-X github.com/bishopfox/sliver/server/version.GitCommit=${gitCommit}"
    "-X github.com/bishopfox/sliver/server/version.CompiledAt=$(date +%s)"
  ];
in
{
  inherit
    src
    version
    gitCommit
    assetOs
    goArch
    zigArch
    goAssetsVersion
    garbleAssetsVersion
    zigAssetsVersion
    goToolchain
    goTarGz
    zigTarXz
    garble
    publicKeyLdflags
    clientVersionLdflags
    serverVersionLdflags
    ;

  packScript = ./pack-sliver-assets.sh;
}