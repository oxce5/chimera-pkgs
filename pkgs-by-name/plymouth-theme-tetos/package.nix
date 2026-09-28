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

  # preview.gif is a few MB of demo footage, not part of the theme.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/plymouth/themes/${finalAttrs.pname}
    cp tetos.plymouth tetos.script $out/share/plymouth/themes/${finalAttrs.pname}/
    cp -r images $out/share/plymouth/themes/${finalAttrs.pname}/

    runHook postInstall
  '';

  # Preview with:
  #   plymouth --show-splash --tty=1 --debug
  passthru = {
    themeDir = "${placeholder "out"}/share/plymouth/themes/${finalAttrs.pname}";
  };

  meta = {
    description = "TetOS Plymouth boot screen theme";
    homepage = "https://github.com/some100/plymouth-theme-tetos";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
