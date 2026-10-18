{
  lib,
  stdenv,
  buildGoModule,
  fetchurl,
  fetchFromGitHub,
  zip,
  bash,
  inputs,
}:
let
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
# sliver-server embeds a Go toolchain, zig and garble for the *host* platform.
# The hash tables in lib/sliver.nix only cover linux tarballs, so without this a
# darwin evaluation happily reuses a linux hash and then fails much later with a
# confusing "hash mismatch". Fail here instead, with a legible message.
assert stdenv.hostPlatform.isLinux || throw ''
  sliver-server is linux-only: the toolchain hashes cover the linux go,
  zig and garble tarballs. sliver-client still builds on darwin.
'';
# Build with the pristine upstream Go rather than nixpkgs' - see lib/sliver.nix.
# It has to be `.override`, not an attribute: buildGoModule is an
# extendMkDerivation, and a plain `go = ...` is silently ignored.
(buildGoModule.override { go = sliver.goToolchain; }) rec {
  pname = "sliver-server";
  version = sliver.version;

  # Source is the `sliver` flake input; bump with `nix flake update sliver`.
  src = sliver.src;

  vendorHash = null;

  # Linux shellcode comes from a `go build -buildmode=c-shared` object handed to
  # malasada. zig (lld) leaves .init_array slots zero and records the address as
  # an R_X86_64_RELATIVE addend; upstream extractInitVaddrs64() reads the slot
  # directly, concludes there are no initialisers, and emits a stub that calls
  # none. Since .init_array[0] is _rt0_amd64_linux_lib, the implant then hangs
  # forever in _cgo_wait_runtime_init_done. The patch resolves the slots through
  # their addends, falling back to the inline value. See AGENTS.md; worth sending
  # upstream to sliverarmory/malasada.
  patches = [./malasada-init-array.patch];

  # NB: no `runHook preBuild`/`runHook postBuild` wrapper here. nixpkgs already
  # turns a `preBuild` attribute into the hook; calling runHook on it recurses
  # until the stack overflows, which the daemon reports as SIGSEGV.
  preBuild = ''
    # Upstream bundles a pristine dl.google.com Go toolchain so implants don't
    # get a Nix store PT_INTERP; doing the same is load-bearing. See AGENTS.md.
    mkdir -p server/assets/fs/${sliver.assetOs}/${sliver.goArch}

    # Copy from goToolchain rather than untarring the tarball a second time:
    # it is the same GOROOT, already materialised in the store for the compiler.
    cp -r ${sliver.goToolchain} $TMPDIR/go
    chmod -R +w $TMPDIR/go

    # Invoked through bash explicitly: the script's `#!/usr/bin/env bash`
    # cannot exec inside the Nix sandbox (no /usr/bin/env there).
    ${bash}/bin/bash ${sliver.packScript} \
      $TMPDIR/go \
      ${sliver.assetOs} \
      ${sliver.goArch} \
      "$PWD/server/assets/fs" \
      ${sliver.garble}/bin/garble \
      ${sliver.zigTarXz} \
      ${zip}/bin/zip
  '';

  ldflags =
    ["-s -w"]
    ++ sliver.publicKeyLdflags
    ++ sliver.clientVersionLdflags
    ++ sliver.serverVersionLdflags;

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

    # Linux only. sliver-server embeds a Go toolchain, zig and garble for the
    # host platform, and we only carry linux hashes for all three.
    platforms = platforms.linux;
  };
}