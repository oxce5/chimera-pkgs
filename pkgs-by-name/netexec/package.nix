{
  lib,
  stdenv,
  fetchFromGitHub,
  python312,
  writableTmpDirAsHomeHook,
}:
let
  python = python312.override {
    self = python;
    packageOverrides = self: super: {
      impacket = super.impacket.overridePythonAttrs {
        version = "0.14.0-unstable-2025-12-03";
        src = fetchFromGitHub {
          owner = "fortra";
          repo = "impacket";
          rev = "caba5facdd3a01b5d0decc6daf5871839f22f792";
          # NOTE: fixed-output store paths do not encode the rev, so a wrong
          # hash here silently substitutes an unrelated cached tree (we once
          # ended up with 0.13.0-dev without LDAP signing support). Always
          # re-verify with nix-prefetch-github when bumping rev.
          hash = "sha256-W7wXgUq34xzqbi/vEyUoKguaBmKeKGd6u3Oce39JHFc=";
        };
        postPatch = ''
          substituteInPlace setup.py \
            --replace 'version="{}.{}.{}.{}{}"' 'version="{}.{}.{}"'
        '';
      };
      bloodhound-py = super.bloodhound-py.overridePythonAttrs (old: {
        dontCheckPythonMetadata = true;
      });
      # Our impacket is a newer-than-release git snapshot (see above), so
      # relax upper bounds pins like impacket~=0.13.0 in dependants.
      certipy-ad = super.certipy-ad.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or []) ++ [ "impacket" ];
      });
      pynfsclient = super.pynfsclient.overridePythonAttrs (old: {
        dontCheckPythonMetadata = true;
      });
    };
  };
  # BloodHound CE ingestor (PyPI). Not in nixpkgs; nxc requires the
  # bloodhound-ce distribution (classic `bloodhound` fails nxc's
  # BloodHound-CE config check) and both provide the top-level
  # `bloodhound` module, so they are mutually exclusive.
  bloodhound-ce = python.pkgs.buildPythonPackage rec {
    # Underscore: PyPI hosts the sdist as bloodhound_ce-1.9.1.tar.gz.
    # The built distribution is still named bloodhound-ce (normalized).
    pname = "bloodhound_ce";
    version = "1.9.1";
    pyproject = true;

    src = python.pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-CD3z3DrZmO3P+Ptj/dj1tGSqtf2sjgXMmztlICEPeas=";
    };

    build-system = with python.pkgs; [ setuptools ];

    dependencies = with python.pkgs; [
      dnspython
      impacket
      ldap3
      pyasn1
      pycryptodome
    ];

    pythonImportsCheck = [ "bloodhound" ];
  };
in
python.pkgs.buildPythonApplication (finalAttrs: {
  pname = "netexec";
  version = "1.5.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Pennyw0rth";
    repo = "NetExec";
    tag = "v${finalAttrs.version}";
    hash = "sha256-BKqBmpA2cSKwC9zX++Z6yTSDIyr4iZVGC/Eea6zoMLQ=";
  };

  pythonRelaxDeps = true;

  postPatch = ''
    substituteInPlace nxc/first_run.py \
      --replace-fail "from os import mkdir" "from os import mkdir, chmod" \
      --replace-fail "shutil.copy(default_path, NXC_PATH)" $'shutil.copy(default_path, CONFIG_PATH)\n        chmod(CONFIG_PATH, 0o600)'

    substituteInPlace pyproject.toml \
      --replace-fail " @ git+https://github.com/Pennyw0rth/Certipy" "" \
      --replace-fail " @ git+https://github.com/fortra/impacket" "" \
      --replace-fail " @ git+https://github.com/wbond/oscrypto" "" \
      --replace-fail " @ git+https://github.com/Pennyw0rth/NfsClient" ""
  '';

  build-system = with python.pkgs; [
    poetry-core
    poetry-dynamic-versioning
  ];

  dependencies = with python.pkgs; [
    jwt
    aardwolf
    aioconsole
    aiosqlite
    argcomplete
    asyauth
    beautifulsoup4
    bloodhound-ce
    certipy-ad
    dploot
    dsinternals
    impacket
    lsassy
    masky
    minikerberos
    msgpack
    msldap
    neo4j
    paramiko
    pefile
    pyasn1-modules
    pylnk3
    pynfsclient
    pypsrp
    pypykatz
    python-dateutil
    python-libnmap
    pywerview
    requests
    rich
    sqlalchemy
    termcolor
    terminaltables
    xmltodict
  ];

  nativeCheckInputs = with python.pkgs; [ pytestCheckHook ] ++ [ writableTmpDirAsHomeHook ];

  meta = {
    description = "Network service exploitation tool (maintained fork of CrackMapExec)";
    homepage = "https://github.com/Pennyw0rth/NetExec";
    changelog = "https://github.com/Pennyw0rth/NetExec/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.bsd2;
    maintainers = with lib.maintainers; [ vncsb ];
    mainProgram = "nxc";
    broken = stdenv.hostPlatform.isDarwin;
  };
})
