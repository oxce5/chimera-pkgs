# Shared plumbing for the Sliver packages.
#
# sliver-client and sliver-server are built from the same `sliver` flake input
# and carry the same public-key ldflags, so that lives here rather than being
# duplicated - and silently diverging - across both package.nix files.
#
# Args are forwarded verbatim by each package so the two stay symmetrical.
# Everything is lazy: a package only forces what it uses, so sliver-client does
# not drag in the toolchain derivations built for sliver-server.
{ lib
, stdenv
, buildGoModule
, fetchurl
, fetchFromGitHub
, go_1_26
, go_1_27
, inputs
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

  # nixpkgs Go matching the toolchain Sliver embeds. Derived from
  # goAssetsVersion rather than pinned, so it cannot drift from the input.
  # Note this only tracks the *minor* version: Sliver asking for a patch level
  # newer than nixpkgs provides still needs GOTOOLCHAIN bumped or nixpkgs moved.
  goPackage =
    if lib.versionAtLeast (lib.versions.majorMinor goAssetsVersion) "1.27"
    then go_1_27
    else go_1_26;

  # Content hashes for the toolchains Sliver downloads at build time. These
  # cannot come from the flake input - they are bytes from dl.google.com and
  # ziglang.org, not from the sliver repo. A version bump without an entry here
  # fails loudly rather than substituting a stale toolchain.
  goTarballHashes = {
    "1.26.6" = {
      amd64 = "sha256-cI7/t3S+gjdXDQrdFjIlq7369PyiiyYR3xZ766T+74k=";
      arm64 = "sha256-0FB+np1/4BKq5XAQjL12wV3oeeFxMKuMuQ1NdEXLHy4=";
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
  garble =
    buildGoModule {
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
      vendorHash = "sha256-F0Jc15ulA+qRDZu5W3FU9dZ+oXq8lGXP4dQeWnZwYbk=";
      # garble rewrites the standard library sources of the GOROOT it is handed,
      # so it must match the toolchain Sliver ships alongside it.
      go = goPackage;
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
    goPackage
    goTarGz
    zigTarXz
    garble
    publicKeyLdflags
    clientVersionLdflags
    serverVersionLdflags
    ;

  packScript = ./pack-sliver-assets.sh;
}