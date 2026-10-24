# AGENTS.md

Nix flake packaging unrelated tools (Sliver, netexec, evil-winrm, iosevka, plymouth
theme, smbclient-ng). Small repo — the hard part is *why* some packages deliberately
deviate from upstream. Read this before "simplifying" anything under `pkgs-by-name/`.

## Layout

- `flake.nix` — flake-parts. Inputs: `nixpkgs`, `flake-parts`,
  `pkgs-by-name-for-flake-parts`, `sliver`.
- `pkgs-by-name/<name>/package.nix` — one dir per package, **the filename must be
  exactly `package.nix`**. `pkgs-by-name/smbclient-ng/` contains an empty file named
  `package` (no `.nix`), so it lands in `legacyPackages` as a non-derivation and is
  silently dropped from `packages`. A stub dir is worse than an empty one.
- `lib/sliver.nix` + `lib/pack-sliver-assets.sh` — shared plumbing for both Sliver
  packages: source resolution, parsing upstream's toolchain versions out of the
  pinned source, the toolchain fetches + hash tables, shared ldflags, and the
  asset-packing step. Both `package.nix` files import it and forward the same args,
  so neither duplicates the other. `lib/` exists because `pkgs-by-name` only loads
  `package.nix`.
- `modules/sliver/default.nix` — NixOS module. Exported as `nixosModules.sliver`.
  Part of it is host-level enablement for `portfwd`: those listeners are created
  by the interactive *client* process, not the daemon, so fake 240/4 addresses
  are aliased onto `lo` and 80/443 are enabled with sysctls
  (`ip_unprivileged_port_start`, `ip_nonlocal_bind`) rather than service
  capabilities — `AmbientCapabilities` on the daemon would not help portfwd at
  all, and Burp/browsers skip the proxy for 127.0.0.0/8.

No formatter is wired up (`formatter` is unset, so `nix fmt` does nothing) and no
test suite: `checks` is empty, CI only runs `nix build`, and both sliver packages
explicitly set `checkPhase = ""`. Verification is "it builds" plus, for Sliver, the
manual ELF checks below.

## Commands

```sh
nix build .#sliver-server            # sliver-client, sliver-server, netexec, ...
nix eval --impure --expr '(builtins.getFlake "path:$PWD").inputs.sliver.outPath'
```
The second one prints the pinned upstream Sliver source tree — read upstream's real
code from there instead of guessing or fetching from the network.

CI (`.github/workflows/build.yml`) only builds on `ubuntu-latest` / x86_64:
`evil-winrm netexec sliver-client sliver-server plymouth-theme-tetos`, plus a
separate `iosevka-chimera` job. **`smbclient-ng` is never built in CI.** So neither
aarch64 nor darwin is exercised by CI — several real bugs below survive there.

## Package functions receive the flake `inputs` attrset

`pkgs-by-name-for-flake-parts` puts the whole `inputs` set in every package's
`callPackage` scope, so a package can declare an `inputs` argument. That is how
`sliver-client` / `sliver-server` get their source — there is **no `fetchFromGitHub`
for Sliver itself**:

```nix
src = inputs.sliver.outPath;                       # source tree
${inputs.sliver.rev}                               # GitCommit ldflag
```

The `sliver` input uses `flake = false` (upstream ships no `flake.nix`). Bump with
`nix flake update sliver`; rev/narHash live in `flake.lock`.

Versions of upstream's embedded toolchains are parsed out of the pinned source
(`util/assets/constants.go`) rather than hardcoded — see `constFromAssets`. Keep that
pattern: hardcoding them is how the repo silently ships a mismatched toolchain.
`builtins.match` is a full-string match, so the pattern only accepts a line that *is*
the declaration; use `[[:space:]]`, not `[ \t]` — an indented Nix string passes `\t`
through unreduced and Nix's regex engine does not understand it.

## Sliver: why these deviations exist

Three deviations are load-bearing. Removing them reintroduces broken implants.

1. **`sliver-server` bundles the official `dl.google.com` Go tarball, not nixpkgs Go.**
   nixpkgs patches `src/internal/buildcfg/zbootstrap.go` to set `DefaultGO_LDSO` to
   `/nix/store/...-glibc-*/lib/ld-linux-x86-64.so.2`, and `cmd/link` uses that as
   `PT_INTERP` for internally linked cgo binaries. Every generated implant then
   refuses to start on any host lacking that store path. The official tarball leaves
   `GO_LDSO` empty so the interpreter comes from the external compiler.
2. **The NixOS module shims `gcc` to sliver's own bundled zig.** For same-arch
   implants `findCrossCompilers()` is never called (it's guarded on
   `runtime.GOOS != config.GOOS || ...` in `server/generate/binaries.go`), so `CC`
   stays empty and cgo falls back to bare `gcc` from `PATH`. Without the shim that is
   Nix's gcc (stamps a Nix interpreter); with *no* `gcc` at all Go silently disables
   cgo and `.so` builds fail cryptically.
   The shim resolves zig at `$SLIVER_ROOT_DIR/zig/zig` — `GetZigDir()` appends `zig`
   to the app dir, and `untarSkipTopLevel` strips the tarball's top-level dir, so
   there is *no* version segment. It targets `-linux-gnu` (not upstream's `-linux-musl`
   default) to keep implants dynamically linked; see the glibc floor below.
3. **`malasada-init-array.patch`.** zig/lld records `.init_array` slots as
   `R_X86_64_RELATIVE` addends rather than inline pointers, which upstream
   `extractInitVaddrs64()` misreads — the shellcode stub then never starts the Go
   runtime. The patch is worth sending upstream to `sliverarmory/malasada`.

Not deviations, despite looking like it: producing `src.zip` on Linux is **required**
(`//go:embed fs/*.zip` with no match is a fatal error), and embedding only the host
platform's assets is correct (the `_linux_amd64.go` filename is a build constraint).

## Nix traps this repo has already hit

- **Never call `runHook preBuild` inside `preBuild`.** nixpkgs already turns a
  `preBuild` attribute into the hook, so `runHook preBuild` recurses until the
  stack overflows and the daemon reports `signal 11 (Segmentation fault)` — with
  no log output, because build stdout is block-buffered and lost when the process
  dies. This cost real time to diagnose; don't reintroduce it.
- **`#!/usr/bin/env bash` does not work in a Nix sandbox** (no `/usr/bin/env`).
  Call shell scripts through `${bash}/bin/bash script args`. A new file under
  `lib/` also has to be `git add`ed before Nix will see it.
- **`meta.platforms` does not gate anything here.** `pkgs-by-name`'s
  `pkgsFilterByPlatforms` defaults to `false`, so `packages.<system>` still lists a
  package on platforms its `meta` excludes. `sliver-server` therefore carries an
  explicit `assert stdenv.hostPlatform.isLinux` — the hash tables only hold linux
  tarballs, and without it a darwin eval happily reuses a linux hash and fails much
  later with a confusing "hash mismatch".
- **Setting `go` on `buildGoModule` needs `.override`.** `buildGoModule` is an
  `extendMkDerivation`, so `buildGoModule { go = X; ... }` is silently ignored and it
  falls back to nixpkgs' Go — you get a confusing `requires go >= 1.27` error instead.
  Use `(buildGoModule.override { go = X; }) { ... }`.
- **Two different hash kinds.** `fetchurl` hashes the flat tarball (`sha256sum` of the
  file), but `fetchFromGitHub` and `vendorHash` hash the *unpacked* tree. Hashing a
  GitHub tarball with `sha256sum` gives a value that never matches; let the build
  print the right one.
- **On the scripted networking backend, `networking.interfaces.lo` is a silent
  no-op.** Its generated `network-addresses-lo.service` gets an empty
  `WantedBy` (the device dependency for `lo` is empty in
  `network-interfaces-scripted.nix`), so it never starts - not on activation,
  not on boot. The module aliases portfwd addresses with its own oneshot
  (`sliver-portfwd-aliases`) instead.
- Hash tables are keyed by version **and** arch. The old hardcoded
  `zig-x86_64-linux` URL meant aarch64 got an x86_64 zig while `meta` claimed
  support; keying by arch is what stops that class of silent breakage.

## Known gaps — verify before assuming something works

- **`modules/sliver/default.nix`: `default = pkgs.sliver`** — that attribute does not
  exist. It only evaluates because `flake.nix` sets `lib.mkDefault`. Importing
  `modules/sliver` directly (without the flake's `nixosModules.sliver`) throws.
- **`ExecStart = "... daemon --force"`** re-extracts `go/` and `zig/` (~100 MB) on
  *every* start and overwrites operator-edited traffic encoders
  (`assets-helpers.go`: `if os.IsNotExist(localPath) || force`). Upstream unpacks once
  and relies on the `assetVersion()` vs `ver.GitCommit` gate, which works here only
  because the ldflags set `GitCommit`.
- **`nix flake update sliver` is now unblocked**, but only because `lib/sliver.nix`
  builds with the *pristine upstream Go tarball* rather than nixpkgs' Go. Upstream's
  `go.mod` asks for a patch level newer than nixpkgs ships (1.27.2 vs go_1_27 =
  1.27.1), and `buildGoModule` hardcodes `GOTOOLCHAIN=local` in a way that wins over
  `env`, so Go cannot fetch a newer toolchain in the sandbox either. One
  `goTarballHashes` entry now serves both the embedded implant toolchain and the
  compiler that builds Sliver, so the version tracks upstream's `goVersion` on its own.
  Raising the pin further needs a new hash there and in `garbleHashes`; garble's
  `vendorHash` is also per-version and the build will report it.

## Operational gotchas

- **Stale implant project dirs break rebuilds.** Sliver does not clear
  `~/.sliver/slivers/<goos>/<goarch>/<name>/`, and `RenameImport` hard-fails on
  `rename import dir: target exists`. Reusing an implant name requires
  `rm -rf /var/lib/sliver/.sliver/slivers/linux/amd64/<name>`. Any failed build (e.g.
  the gcc shim exiting 127) leaves a partial dir that poisons retries.
- **Fixed-output hashes do not encode the rev.** A wrong `hash` next to a bumped
  `rev` silently substitutes an unrelated cached tree. Re-verify with
  `nix-prefetch-github` / `nix-prefetch-url`. `netexec` carries a comment about
  actually hitting this.

## Verifying an implant (the de facto test)

There is no automated check that implants are sound. After building one:

```sh
readelf -dl ./implant | grep -E 'INTERP|NEEDED|RPATH|RUNPATH'   # want /lib64/ld-linux-*, bare sonames, no rpath
objdump -T ./implant | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
```

To check a *packaging* change did not alter the embedded assets, carve them back
out of the binary and compare content hashes — the outer binary legitimately differs
(build timestamps), the assets must not:

```sh
# go.zip / src.zip are plain zips embedded verbatim; scan backwards for EOCD
# records (PK\x05\x06), recompute each archive's start as
#   eocd + 22 - cdSize - cdOffset, then hash names + contents.
```

Run the first block on the *target* host if you can. `ldd` output is misleading when
run on a NixOS box — the loader resolves bare sonames to `/nix/store/...glibc` from
its own cache, which says nothing about the binary. Note the glibc floor: the module
targets `x86_64-linux-gnu` without a version suffix, which floors symbol versions at
`GLIBC_2.27` (fine on Ubuntu 20.04+/Debian 10+, breaks on CentOS 7 / Debian 9).
Appending `.2.17` to the triple lowers it to `GLIBC_2.10`; `-linux-musl -static`
removes the libc dependency entirely.

## CI gotchas

`.github/workflows/build.yml` builds one package per matrix job (`fail-fast: false`),
plus a separate `font` job for `iosevka-chimera`. It runs on **every** branch push and
every PR (`branches: ["**"]`), but the Cachix steps are gated on
`github.ref == 'refs/heads/chimera-pkgs'`, so **only main writes to the shared cache** —
branches and PRs build but never push.

`.github/workflows/push-cache.yml` is `workflow_dispatch` only: the deliberate way to
seed `chimera-pkgs` from a branch before merging it (optional `packages` input narrows
the matrix). Its token check fails unconditionally, since it exists to push.

GitHub reports matrix legs as `packages (<name>)`, so there is no aggregate `packages`
check to require — hence the `packages-gate` job, which `needs: packages` and is the
single stable status check. Merging to `main` therefore needs **required status checks**
on `packages-gate` and `font`, or nothing gates the merge. Branch protection is already
configured on the remote for exactly those two.

- Pushes to `chimera-pkgs` **fail without `CACHIX_AUTH_TOKEN`** — intentional, so a
  broken secret is loud rather than silently stopping the cache from being populated.
  That gate is main-only, so the secret is never consulted on branches or PRs.
- `fail-fast: false` keeps the other legs running after one fails; `packages-gate`
  still fails, so gating is unaffected.
- The `iosevka-chimera` job aborts if `nix build --dry-run` shows nodejs would be
  compiled from source (multi-hour V8 build). Re-run once Hydra has it; do not
  "fix" the guard.
- CI sets `experimental-features = nix-command flakes` via `install-nix-action`, so
  flakes work without a local flag there.