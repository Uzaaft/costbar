{
  description = "💸";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems = {
      url = "github:nix-systems/default";
      flake = false;
    };
  };

  outputs = {
    nixpkgs,
    systems,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;

    platforms = import systems;
    forAllPlatforms = f: lib.genAttrs platforms (system: f legacyPackages.${system});
  in {
    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {};
    });

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);
  };
}
