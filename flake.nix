{
  description = "Chimera packages";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    # pinned due to nodejs slim building
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
    pkgs-by-name-for-flake-parts.url = "github:drupol/pkgs-by-name-for-flake-parts";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.pkgs-by-name-for-flake-parts.flakeModule];

      systems = inputs.nixpkgs.lib.systems.flakeExposed;

      perSystem = {
        pkgs,
        system,
        config,
        ...
      }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              local = config.packages;
            })
          ];
        };

        pkgsDirectory = ./pkgs-by-name;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [go gopls];
        };
      };

      flake.nixosModules.sliver = {
        lib,
        pkgs,
        ...
      }: {
        imports = [./modules/sliver];
        services.sliver.package =
          lib.mkDefault
          self.packages.${pkgs.stdenv.hostPlatform.system}.sliver-server;
      };
    };
}
