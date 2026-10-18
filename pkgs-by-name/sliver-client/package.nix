{
  lib,
  stdenv,
  buildGoModule,
  fetchurl,
  fetchFromGitHub,
  inputs,
}:
let
  # Args are forwarded verbatim so both Sliver packages import the shared lib
  # identically. Nothing beyond the attributes used below is forced.
  sliver = import ../../lib/sliver.nix {
    inherit
      lib
      stdenv
      buildGoModule
      fetchurl
      fetchFromGitHub
      inputs
      ;
  };
in
# Build with the pristine upstream Go rather than nixpkgs' - see lib/sliver.nix.
# It has to be `.override`, not an attribute: buildGoModule is an
# extendMkDerivation, and a plain `go = ...` is ignored.
(buildGoModule.override { go = sliver.goToolchain; }) rec {
  pname = "sliver-client";
  version = sliver.version;

  # Source is the `sliver` flake input; bump with `nix flake update sliver`.
  src = sliver.src;

  vendorHash = null;

  ldflags =
    ["-s -w"]
    ++ sliver.publicKeyLdflags
    ++ sliver.clientVersionLdflags;

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

    # Unlike the server, the client builds no assets and is pure Go, so macOS
    # needs no toolchain hashes of its own.
    platforms = platforms.linux ++ platforms.darwin;
  };
}