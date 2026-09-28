{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "plymouth-theme-tetos";
  version = "2025-01-24";

  src = fetchFromGitHub {
    owner = "some100";
    repo = "plymouth-theme-tetos";
    rev = "db2d2d78f8243ba6df67940d8adcf84bd067345a";
    hash = "sha256-Z4crWszInL+V1mHludmQ6ZK7vIfSpzFVgMXSRLCL38I=";
  };

  # plymouth requires the theme directory to be named after the .plymouth
  # file it contains, and the initrd builder (nixos plymouth module) resolves
  # the theme as <themes>/<theme>/<theme>.plymouth.
  themeName = "tetos";

  # preview.gif is a few MB of demo footage, not part of the theme.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/plymouth/themes/${finalAttrs.themeName}
    cp tetos.plymouth tetos.script $out/share/plymouth/themes/${finalAttrs.themeName}/
    cp -r images $out/share/plymouth/themes/${finalAttrs.themeName}/

    # The theme hardcodes /usr/share/plymouth/themes. Point it at the store
    # instead, so the NixOS plymouth module's initrd fixup (which rewrites
    # $storeDir/.../share/plymouth/themes to the initrd theme dir) can find it.
    for f in $out/share/plymouth/themes/${finalAttrs.themeName}/*.plymouth \
             $out/share/plymouth/themes/${finalAttrs.themeName}/*.script; do
      substituteInPlace "$f" \
        --replace /usr/share/plymouth/themes "$out/share/plymouth/themes"
    done

    runHook postInstall
  '';

  # Preview with:
  #   plymouth --show-splash --tty=1 --debug
  passthru = {
    inherit (finalAttrs) themeName;
    themeDir = "${placeholder "out"}/share/plymouth/themes/${finalAttrs.themeName}";
  };

  meta = {
    description = "TetOS Plymouth boot screen theme";
    homepage = "https://github.com/some100/plymouth-theme-tetos";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
