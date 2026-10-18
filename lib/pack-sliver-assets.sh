#!/usr/bin/env bash
# Pack the build assets that sliver-server embeds, replacing upstream's
# util/assets generator (which downloads everything at build time - not
# something a Nix build can do).
#
# Ordering and the removal set mirror util/assets/go.go:
#   bloat removal -> src.zip -> drop src/ -> drop doc/tour/test2json -> go.zip
#
# usage: pack-sliver-assets.sh GOROOT OS ARCH OUTDIR GARBLE ZIGTARBALL ZIP
set -euo pipefail

goroot=$1
os=$2
arch=$3
outdir=$4
garble=$5
zigtarball=$6
zipbin=$7

dest="$outdir/$os/$arch"
mkdir -p "$dest"

# util/assets/constants.go goBloatPaths. codereview.cfg, go.env and LICENSE
# are deliberately kept - upstream keeps them too.
rm -rf "${goroot:?}"/api "${goroot:?}"/doc "${goroot:?}"/misc "${goroot:?}"/test
rm -f \
  "${goroot:?}"/AUTHORS "${goroot:?}"/CONTRIBUTORS "${goroot:?}"/PATENTS \
  "${goroot:?}"/VERSION "${goroot:?}"/favicon.ico "${goroot:?}"/robots.txt \
  "${goroot:?}"/SECURITY.md "${goroot:?}"/CONTRIBUTING.md "${goroot:?}"/README.md

# src.zip is mandatory even though upstream only sets includeSrc for darwin:
# //go:embed fs/*.zip fails the build outright if no file matches, and the
# runtime unpacks src.zip on every platform.
(cd "$goroot" && "$zipbin" -r -q "$outdir/src.zip" src/)

rm -rf "${goroot:?}/src"
rm -f "${goroot:?}/pkg/tool/${os}_${arch}"/doc \
      "${goroot:?}/pkg/tool/${os}_${arch}"/tour \
      "${goroot:?}/pkg/tool/${os}_${arch}"/test2json

# Archive the GOROOT from its parent so entries are rooted at "go/".
(cd "$(dirname "$goroot")" && "$zipbin" -r -q "$dest/go.zip" go/)

# install(1) rather than cp so the executable bit on garble is explicit.
install -Dm755 "$garble" "$dest/garble"
install -Dm644 "$zigtarball" "$dest/zig.tar.xz"